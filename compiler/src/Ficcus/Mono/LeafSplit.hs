{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE PatternGuards #-}
module Ficcus.Mono.LeafSplit
  ( SplitFacts(..)
  , Plan(..)
  , planSplit
  , dealiasOnly
  , rewriteSplit
  , leafSplitOn
  , splitStatsOn
  )
  where


-- Ficcus, E1p (docs/E1P-DESIGN.md section 2): the leaf split of an owned struct variable, the analysis half. The Rc pass
-- (Ficcus.Mono.Rc.trySplit) asks, at an expression `e` where the owned struct variable `m` dies and that its own conditions allow
-- (owned, not live after `e`, not the root of a view, not late, not an owned capture of a twin):
--
--   * `planSplit`: is every use of `m` in `e` a field read `m.f` or a whole use in an owned position (no binder rebinds `m`, no lifted
--     function captures it), after the dealias of `let x = m` where `x` is read only by field? And does the split pay (condition 3):
--       (a) a reference field read in a consumed position, or a whole use, that is not `m`'s last use on its path (without the split
--           it is a dup), or
--       (b) `m` has a reference field that `e` never fieldReads, and a call with a reference argument runs before a later use of `m` (the
--           unread leaf would be held across it)?
--   * `rewriteSplit`: `e` with every `m.f` replaced by the variable of field f and every whole `m` by the record of all of them.
--
-- The Rc pass then makes `case m of { f1 = v1, .. } -> e'`, which its ordinary `rcCase` turns into an `MUnpack` (no new IR node, no
-- new checker rule). Everything here is a pure look at the expression: it decides where the split happens, never a count.


import qualified Data.List as List
import qualified Data.Map.Strict as Map
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)

import Ficcus.Mono.Class
import Ficcus.Mono.Free (refClass, patVars)
import Ficcus.Mono.Ir
import Ficcus.Mono.Kernel (kernelSig)


{-# NOINLINE leafSplitOn #-}
-- | the split is on by default; FICCUS_NO_LEAFSPLIT=1 (or FICCUS_NO_LEAF_SPLIT=1, the design note's name) gives the E2g pass exactly
leafSplitOn :: Bool
leafSplitOn = unsafePerformIO $
  do  a <- lookupEnv "FICCUS_NO_LEAFSPLIT"
      b <- lookupEnv "FICCUS_NO_LEAF_SPLIT"
      return (a /= Just "1" && b /= Just "1")


{-# NOINLINE splitStatsOn #-}
-- | FICCUS_SPLIT_STATS=1: the splits per clone on stderr (printed by the driver)
splitStatsOn :: Bool
splitStatsOn = unsafePerformIO (fmap (== Just "1") (lookupEnv "FICCUS_SPLIT_STATS"))


-- | what the analysis needs of the program
data SplitFacts =
  SplitFacts
    { sfCaps :: Map.Map CloneId [(String, Class)]     -- the captured variables of every lifted clone
    , sfClones :: Map.Map CloneId MDef
    }


-- | a split that pays: the expression after the dealias, the fields to bind (position, name, class) and whether `m` is used whole
-- (then every field is bound)
data Plan =
  Plan
    { plExpr :: MExpr
    , plFields :: [(Int, String, Class)]
    , plWhole :: Bool
    }


-- | `m` (of struct class with these field classes) at `e`: Nothing when a use is not a field read or an owned whole use, or when the
-- split would save nothing
planSplit :: SplitFacts -> String -> [Class] -> MExpr -> Maybe Plan
planSplit facts m fs e0 =
  do  let e = dealias facts m e0
      uses <- usesOf facts m fs True e
      let fieldReads = List.nubBy (\(i, _, _) (j, _, _) -> i == j) (List.sortOn (\(i, _, _) -> i) [ r | Left r <- uses ])
          whole = not (null [ () | Right () <- uses ])
          names = Map.fromList [ (i, f) | (i, f, _) <- fieldReads ]
          fields = if whole then [ (i, Map.findWithDefault ("f" ++ show i) i names, c) | (i, c) <- zip [0 ..] fs ] else fieldReads
          unread = not whole && or [ refClass c && not (Map.member i names) | (i, c) <- zip [0 :: Int ..] fs ]
      if not (null uses) && rProf (analyse facts m unread True False False e)
        then Just (Plan e fields whole)
        else Nothing


-- | the plan carried out: fieldReads of the bound fields become their variables (`var i`), a whole use the record of all of them
rewriteSplit :: String -> [Class] -> Plan -> (Int -> String) -> MExpr
rewriteSplit m fs plan var = go (plExpr plan)
  where
    names = Map.fromList [ (i, f) | (i, f, _) <- plFields plan ]
    whole = MExpr (CStruct fs) (MRecord [ (Map.findWithDefault ("f" ++ show i) i names, MExpr c (MLocal (var i))) | (i, c) <- zip [0 ..] fs ])
    go x =
      case mNode x of
        MAccess (MExpr _ (MLocal n)) _ i | n == m -> MExpr (mRep x) (MLocal (var i))
        MLocal n | n == m -> whole
        _ -> mapChildren go x


-- THE USES

-- | every use of `m` in `e`: Left (position, name, class) for a field read, Right () for a whole use; Nothing when a use is of another
-- kind (a whole use in a borrowed position or as a scrutinee), a binder rebinds `m`, or a lifted function captures it
usesOf :: SplitFacts -> String -> [Class] -> Bool -> MExpr -> Maybe [Either (Int, String, Class) ()]
usesOf facts m fs = go
  where
    go own x =
      case mNode x of
        MAccess (MExpr _ (MLocal n)) f i
          | n == m -> if i < length fs && fs !! i == mRep x then Just [Left (i, f, mRep x)] else Nothing
        MLocal n
          | n == m -> if own then Just [Right ()] else Nothing
          | otherwise -> Just []
        MGlobal c
          | m `elem` map fst (Map.findWithDefault [] c (sfCaps facts)) -> Nothing
          | otherwise -> Just []
        MLetVal n v b
          | n == m -> Nothing
          | otherwise -> (++) <$> go True v <*> go True b
        MLam ps _
          | m `elem` map fst ps -> Nothing
        MCase s bs
          | any (\(p, _) -> m `elem` patVars p) bs -> Nothing
          | MLocal n <- mNode s, n == m -> Nothing
          | otherwise -> concat <$> mapM (go True) (s : map snd bs)
        MCall h args -> concat <$> sequence (go False h : [ go o a | (o, a) <- zip (argOwns facts h args) args ])
        MAccess r _ _ -> go False r
        _ -> concat <$> mapM (go True) (children x)


-- | for each argument of a call: is it in an owned position? (a borrowed function parameter of the same class, a `b` kernel argument:
-- not owned; a function value's arguments, a constructor's: owned)
argOwns :: SplitFacts -> MExpr -> [MExpr] -> [Bool]
argOwns facts h args =
  case mNode h of
    MKernel name key
      | Just sig <- kernelSig name key, length sig == length args -> map (== 'o') sig
    MGlobal c
      | Just d <- Map.lookup c (sfClones facts), mdKind d == Function, length args == length (mdParams d) ->
          [ not (o == Borrowed && mRep a == pc) | (a, o, (_, pc)) <- zip3 args (paramOwns d) (mdParams d) ]
    _ -> map (const True) args


-- THE PROFITABILITY (condition 3)

data R = R { rProf :: Bool, rUses :: Bool, rCalls :: Bool }


-- | `analyse own later before e`: `own` = e is in an owned position, `later` = `m` is used after `e` on this path, `before` = a call
-- with a reference argument ran before `e` on this path. Lazy: a child's flags come from its siblings' `rUses`/`rCalls`, which do
-- not depend on the flags.
analyse :: SplitFacts -> String -> Bool -> Bool -> Bool -> Bool -> MExpr -> R
analyse facts m unread = go
  where
    go own later before x =
      case mNode x of
        MAccess (MExpr _ (MLocal n)) _ _
          | n == m -> R ((refClass (mRep x) && own && later) || (unread && before)) True False
        MLocal n
          | n == m -> R (later || (unread && before)) True False
          | otherwise -> R False False False
        MIf bs f -> chain own later before bs f
        MCase s bs ->
          let rs = go True (later || any (mentions . snd) bs) before s
              before' = before || rCalls rs
              rb = [ go True later before' b | (_, b) <- bs ]
          in R (rProf rs || any rProf rb) (rUses rs || any rUses rb) (rCalls rs || any rCalls rb)
        MCall h args ->
          let r = sequential later before ((False, h) : zip (argOwns facts h args) args)
          in r { rCalls = rCalls r || any (refClass . mRep) args }
        MAccess r _ _ -> sequential later before [(False, r)]
        _ -> sequential later before [ (True, c) | c <- children x ]
    -- the children in evaluation order
    sequential later before kids =
      let rs = [ go o (later || any rUses after) (before || any rCalls prior) c
               | (k, (o, c)) <- zip [0 :: Int ..] kids, let prior = take k rs, let after = drop (k + 1) rs ]
      in R (any rProf rs) (any rUses rs) (any rCalls rs)
    -- `if c1 then b1 else if ...`: each condition runs before its branch and the rest of the chain
    chain own later before bs f =
      case bs of
        [] -> go own later before f
        (c, b) : rest ->
          let restUses = any (\(c', b') -> mentions c' || mentions b') rest || mentions f
              rc = go True (later || mentions b || restUses) before c
              before' = before || rCalls rc
              rb = go own later before' b
              rr = chain own later before' rest f
          in R (rProf rc || rProf rb || rProf rr) (rUses rc || rUses rb || rUses rr) (rCalls rc || rCalls rb || rCalls rr)
    mentions x =
      case mNode x of
        MLocal n -> n == m
        _ -> any mentions (children x)


-- THE DEALIAS

-- | `let x = m in b`, where `b` fieldReads `x` only by field, does not rebind `m` and no lifted function in `b` captures `x`: `b` with
-- `x.f := m.f` (the record update temporary `_upK` of Spec, and any other alias). As ModelUnpack's dealias, for any owned struct.
dealias :: SplitFacts -> String -> MExpr -> MExpr
dealias facts m = go
  where
    go e =
      case mNode e of
        MLetVal t v@(MExpr _ (MLocal n)) b
          | n == m, t /= m, fieldOnly t b, not (rebinds b), not (captured t b) ->
              go (substAccess t (\a -> case mNode a of { MAccess _ f i -> MExpr (mRep a) (MAccess v f i); _ -> a }) b)
        MLetVal t _ _ | t == m -> e
        MLam ps _ | m `elem` map fst ps -> e
        MCase s bs -> MExpr (mRep e) (MCase (go s) [ (p, if m `elem` patVars p then b else go b) | (p, b) <- bs ])
        _ -> mapChildren go e
    -- t used other than as the record of a field read
    fieldOnly t x =
      case mNode x of
        MAccess (MExpr _ (MLocal n)) _ _ | n == t -> True
        MLocal n -> n /= t
        _ -> all (fieldOnly t) (children x)
    rebinds x =
      case mNode x of
        MLetVal n _ _ | n == m -> True
        MLam ps _ | m `elem` map fst ps -> True
        MCase _ bs | any (\(p, _) -> m `elem` patVars p) bs -> True
        _ -> any rebinds (children x)
    captured t x =
      case mNode x of
        MGlobal c -> t `elem` map fst (Map.findWithDefault [] c (sfCaps facts))
        _ -> any (captured t) (children x)


-- | the dealias alone (E1p review fix 3), where no split pays: Just the expression when it removed at least one `let x = m`. It never
-- adds a count: `m` lives as long as `x` did and its reads are the reads `x` had; it removes the `Dup m` of the `let` (cause C2 of the
-- design note: `{ m | n = m.n + 1 }` on a struct whose only reference field is moved by its last read)
dealiasOnly :: SplitFacts -> String -> MExpr -> Maybe MExpr
dealiasOnly facts m e =
  let e' = dealias facts m e
  in if aliasLets e' < aliasLets e then Just e' else Nothing
  where
    aliasLets x =
      case mNode x of
        MLetVal _ (MExpr _ (MLocal n)) b | n == m -> 1 + aliasLets b
        _ -> sum (map aliasLets (children x)) :: Int


-- | every field read of `t` (outside binders that shadow it) replaced by `new` of the read
substAccess :: String -> (MExpr -> MExpr) -> MExpr -> MExpr
substAccess t new = go
  where
    go e =
      case mNode e of
        MAccess (MExpr _ (MLocal n)) _ _ | n == t -> new e
        MLetVal n v b | n == t -> MExpr (mRep e) (MLetVal n (go v) b)
        MLam ps _ | t `elem` map fst ps -> e
        MCase s bs -> MExpr (mRep e) (MCase (go s) [ (p, if t `elem` patVars p then b else go b) | (p, b) <- bs ])
        _ -> mapChildren go e


-- | the node with `f` applied to its direct sub-expressions (the specializer's nodes; the Rc nodes do not exist yet)
mapChildren :: (MExpr -> MExpr) -> MExpr -> MExpr
mapChildren f x@(MExpr c node) =
  case node of
    MCall h args -> MExpr c (MCall (f h) (map f args))
    MLam ps b -> MExpr c (MLam ps (f b))
    MIf bs e -> MExpr c (MIf [ (f a, f b) | (a, b) <- bs ] (f e))
    MLetVal n v b -> MExpr c (MLetVal n (f v) (f b))
    MSeq a b -> MExpr c (MSeq (f a) (f b))
    MCase s bs -> MExpr c (MCase (f s) [ (p, f b) | (p, b) <- bs ])
    MAccess r n i -> MExpr c (MAccess (f r) n i)
    MUpdate r fs -> MExpr c (MUpdate (f r) [ (n, f v) | (n, v) <- fs ])
    MRecord fs -> MExpr c (MRecord [ (n, f v) | (n, v) <- fs ])
    MTuple xs -> MExpr c (MTuple (map f xs))
    MList xs -> MExpr c (MList (map f xs))
    MReuse t b -> MExpr c (MReuse t (f b))
    MFreeTok t b -> MExpr c (MFreeTok t (f b))
    _ -> x
