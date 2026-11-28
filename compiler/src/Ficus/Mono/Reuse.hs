{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE PatternGuards #-}
module Ficus.Mono.Reuse
  ( Cell(..)
  , cellOfPat
  , appCell
  , placeToken
  , reuseCandidates
  )
  where


-- Ficus, stage (iv) slice S4: constructor reuse (docs/STAGE4-PLAN.md, section 14).
--
-- A branch `case x of C a b -> body` in which `x` is an owned variable that dies at the match can keep the cell of `x` as a *reuse token*
-- when it is unique (drop specialization, `MSpec`) and build the first constructor application of the same size class in `body` in that
-- cell (`MReuse`) instead of allocating. This module is the structural part, shared by the Rc pass, the borrow inference (which makes a
-- parameter owned when its case is a reuse candidate) and the checker:
--
--   * `cellOfPat`: the patterns that can be specialized (one constructor or `::`, arguments are variables or wildcards);
--   * `appCell`: the constructor applications that can use a token, and the layout of the cell they build;
--   * `placeToken`: where in a branch body the token is used. It is used by the first constructor application of the right size class
--     that is evaluated on the path (an argument of a call, a `let` value, a field of a record, the scrutinee or first condition of a
--     tail `case`/`if`); the arms of a case or `if` in tail position (nothing is evaluated after them) each place it separately, and an
--     arm that has no such application frees the token at its start (`MFreeTok`). An expression in a conditional position (an arm that
--     is not in tail position, a later condition, the right operand of `&&`) is not searched, so on every path the token is consumed
--     exactly once.


import Ficus.Mono.Class
import Ficus.Mono.Ir
import Ficus.Mono.Layout (objSizeClass)


-- | a constructor or cons pattern whose arguments are variables or wildcards
data Cell =
  Cell
    { cellFields :: [Class]                  -- the field classes of the heap object (a struct field is boxed)
    , cellVars :: [(Int, String, Class)]     -- field index, name and class of each pattern variable
    }


boxed :: Class -> Class
boxed c = case c of { CStruct _ -> CRef; _ -> c }


cellOfPat :: MPat -> Maybe Cell
cellOfPat (MPat _ node) =
  case node of
    PCtor _ _ ps | not (null ps), all simple ps -> Just (Cell (map (boxed . mpRep) ps) (vars ps))
    PCons h t | simple h, simple t -> Just (Cell [boxed (mpRep h), CRef] (vars [h, t]))
    _ -> Nothing
  where
    simple q = case mpNode q of { PVar _ -> True; PWild -> True; _ -> False }
    vars ps = [ (i, v, mpRep q) | (i, q) <- zip [0 :: Int ..] ps, PVar v <- [mpNode q] ]


-- | the field classes of the object a constructor application (or a cons) builds
appCell :: MExpr -> Maybe [Class]
appCell e =
  case mNode e of
    MCall h args ->
      case mNode h of
        MCtor _ _ (Key parts) | not (null args), let cs = [ c | ByClass c <- parts ], length cs == length args -> Just cs
        MKernel "elm/core:List.cons" (Key [ByClass c]) | length args == 2 -> Just [c, CRef]
        _ -> Nothing
    _ -> Nothing


-- | the body with the token (named `tok`, size class `k`) used by the first fitting application on every path; `Nothing` when no path
-- has one (then there is no token)
placeToken :: String -> Int -> MExpr -> Maybe MExpr
placeToken tok k = go True
  where
    fits e = case appCell e of { Just cs -> objSizeClass cs == Just k; Nothing -> False }
    wrap e = MExpr (mRep e) (MReuse tok e)
    -- the first element (in evaluation order) that uses the token; the others are left alone
    firstOf :: [MExpr] -> Maybe [MExpr]
    firstOf [] = Nothing
    firstOf (x : xs) =
      case go False x of
        Just x' -> Just (x' : xs)
        Nothing -> (x :) <$> firstOf xs
    go :: Bool -> MExpr -> Maybe MExpr
    go tl e =
      let node = MExpr (mRep e)
      in
      case mNode e of
        MCall h args
          | MKernel name _ <- mNode h, name `elem` ["elm/core:Basics.and", "elm/core:Basics.or"] ->
              case args of
                a : rest -> (\a' -> node (MCall h (a' : rest))) <$> go False a
                [] -> Nothing
          | otherwise ->
              case firstOf args of
                Just args' -> Just (node (MCall h args'))
                Nothing | fits e -> Just (wrap e)
                        | otherwise -> Nothing
        MLetVal n v b ->
          case go False v of
            Just v' -> Just (node (MLetVal n v' b))
            Nothing -> node . MLetVal n v <$> go tl b
        MSeq a b ->
          case go False a of
            Just a' -> Just (node (MSeq a' b))
            Nothing -> node . MSeq a <$> go tl b
        MRecord fs -> (\xs -> node (MRecord (zip (map fst fs) xs))) <$> firstOf (map snd fs)
        MTuple xs -> node . MTuple <$> firstOf xs
        MList xs -> node . MList <$> firstOf xs
        MAccess r f i -> (\r' -> node (MAccess r' f i)) <$> go False r
        MIf bs final -> ifChain tl node bs final
        MCase s bs ->
          case go False s of
            Just s' -> Just (node (MCase s' bs))
            Nothing
              | tl ->
                  let arms = [ (p, arm b) | (p, b) <- bs ]
                  in if any (snd . snd) arms then Just (node (MCase s [ (p, fst a) | (p, a) <- arms ])) else Nothing
              | otherwise -> Nothing
        MFreeTok t b -> node . MFreeTok t <$> go tl b
        _ -> Nothing
    -- an arm in tail position: it uses the token or frees it at its start
    arm :: MExpr -> (MExpr, Bool)
    arm b = case go True b of { Just b' -> (b', True); Nothing -> (MExpr (mRep b) (MFreeTok tok b), False) }
    -- `if c then b else (if ... )`: the later conditions are evaluated only when the earlier ones are false, so the rest of the chain is
    -- an `if` of its own in the else arm
    ifChain tl node bs final =
      case bs of
        [] -> Nothing
        (c, b) : rest ->
          case go False c of
            Just c' -> Just (node (MIf ((c', b) : rest) final))
            Nothing
              | tl ->
                  let (b', usedB) = arm b
                      elseE = if null rest then final else node (MIf rest final)
                      (e', usedE) = arm elseE
                  in if usedB || usedE then Just (node (MIf [(c, b')] e')) else Nothing
              | otherwise -> Nothing


-- | the case branches in tail position of a function body that are candidates for reuse: (scrutinee variable, pattern, branch body)
reuseCandidates :: MExpr -> [(String, MPat, MExpr)]
reuseCandidates = go
  where
    go e =
      case mNode e of
        MIf bs f -> concat (go f : [ go b | (_, b) <- bs ])
        MLetVal _ _ b -> go b
        MSeq _ b -> go b
        MCase s bs ->
          concat [ [ (n, p, b) | MLocal n <- [mNode s], mRep s == CRef ] ++ go b | (p, b) <- bs ]
        MFreeTok _ b -> go b
        _ -> []
