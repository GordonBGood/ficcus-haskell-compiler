{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE FlexibleContexts, PatternGuards #-}
module Ficcus.Mono.RcCheck
  ( rcCheck
  )
  where


-- Ficcus, stage (iv) slice S2: the independent static checker of the Rc pass (docs/STAGE4-PLAN.md, section 10, item 1).
--
-- It knows nothing of how the pass decides: it takes the annotated Mono (with `MDup`, `MDrop`, `MOwn`) and walks every path of
-- every clone in evaluation order, holding for each variable the number of counts the scope owns:
--
--   * a use in an OWNED position (an argument of an owned parameter, a constructor field, the returned value, a captured variable
--     of a closure, `MDrop`) takes one of the counts: it is an error when there is none (use after the last consumption);
--   * a use in a BORROWED position (a borrowed kernel argument, the scrutinee of a case, the record of a field access, a captured
--     variable passed to a lifted function) needs the variable to be readable: it has a count, or it is a view (a pattern variable, a
--     captured parameter) of something that is still readable;
--   * `MDup` adds a count, `MOwn` makes an owned value of something that is only looked at;
--   * a branch must leave every variable with the same number of counts as the other branches (an owned variable consumed on one
--     path and not on the other is a leak or a double free), a `let` variable and a pattern variable must have no counts left at
--     the end of their scope, and a function must end with none of its owned parameters left;
--   * the expressions that have no count of their own (a bare string literal, a global, a nullary constructor, a static closure)
--     must not be in an owned position: the pass wraps them in `MOwn`.
--
-- The kernel signatures come from Ficcus.Mono.Kernel (the same table the pass uses: the checker checks the use of the table, not
-- the table).


import Control.Monad (forM_, unless, when, zipWithM_)
import Control.Monad.State.Strict (StateT(..), evalStateT, get, gets, modify')
import qualified Data.Map.Strict as Map

import Ficcus.Mono.Class
import Ficcus.Mono.Free
import Ficcus.Mono.Ir
import Ficcus.Mono.Kernel (kernelResultBorrowed, kernelSig)


data V =
  V
    { vOwned :: Bool                    -- a variable with a count of its own (a parameter, a let, a dup'd view), not a view
    , vCount :: Int
    , vRoot :: Maybe String             -- the variable a view looks into
    }


type Scope = Map.Map String V


data Cx =
  Cx
    { cxScope :: Scope
    , cxClones :: Map.Map CloneId MDef
    , cxCaps :: Map.Map CloneId [(String, Class)]
    }


type CK a = StateT Cx (Either String) a


-- | the violations of the counting rules in the program, as messages (empty: the program is correct)
rcCheck :: MProgram -> [String]
rcCheck program =
  let clones = mpClones program
      caps = captures clones
      byId = Map.fromList [ (mdClone d, d) | d <- clones ]
  in [ msg
     | d <- clones, Just (mdClone d) /= mpMain program, Just body <- [mdBody d]
     , Left err <- [evalStateT (checkDef d caps body) (Cx Map.empty byId caps)]
     , let msg = "rc check: " ++ mdName d ++ ": " ++ err ]


bad :: String -> CK a
bad msg = StateT (\_ -> Left msg)


checkDef :: MDef -> Map.Map CloneId [(String, Class)] -> MExpr -> CK ()
checkDef d caps body =
  do  let capVars = [ n | (n, c) <- Map.findWithDefault [] (mdClone d) caps, refClass c ]
      let params = [ n | (n, c) <- mdParams d, refClass c ]
      modify' (\s -> s { cxScope = Map.fromList ([ (n, V True 1 Nothing) | n <- params ] ++ [ (n, V False 0 Nothing) | n <- capVars ]) })
      owned body
      sc <- gets cxScope
      forM_ (Map.toList sc) $ \(n, v) ->
        when (vCount v /= 0) (bad ("variable " ++ n ++ " has " ++ show (vCount v) ++ " count(s) left at the end of the function"))


-- VARIABLES

readable :: String -> CK Bool
readable n =
  do  sc <- gets cxScope
      return (isReadable sc n)


isReadable :: Scope -> String -> Bool
isReadable sc n =
  case Map.lookup n sc of
    Nothing -> False
    Just v
      | vCount v > 0 -> True
      | vOwned v -> False
      | otherwise -> maybe True (isReadable sc) (vRoot v)


-- a use that reads the variable
borrow :: String -> CK ()
borrow n =
  do  ok <- readable n
      unless ok (bad ("variable " ++ n ++ " is read when it is not alive (no count and no live owner)"))


-- a use that takes a count
consume :: String -> CK ()
consume n =
  do  sc <- gets cxScope
      case Map.lookup n sc of
        Nothing -> bad ("variable " ++ n ++ " is consumed but is not in scope")
        Just v
          | vCount v <= 0 -> bad ("variable " ++ n ++ " is consumed when it has no count (used after its last use, or a view used as owned)")
          | otherwise -> modify' (\s -> s { cxScope = Map.insert n v { vCount = vCount v - 1 } sc })


addCount :: String -> CK ()
addCount n =
  do  borrow n
      modify' (\s -> s { cxScope = Map.adjust (\v -> v { vCount = vCount v + 1 }) n (cxScope s) })


-- a variable of this class with one count, for the scope of `body`; it must have none left at the end
withOwned :: String -> Class -> CK a -> CK a
withOwned n c body =
  if not (refClass c) then body
  else
    do  old <- gets (Map.lookup n . cxScope)
        modify' (\s -> s { cxScope = Map.insert n (V True 1 Nothing) (cxScope s) })
        r <- body
        v <- gets (Map.lookup n . cxScope)
        case v of
          Just x | vCount x /= 0 -> bad ("variable " ++ n ++ " has " ++ show (vCount x) ++ " count(s) left at the end of its scope")
          _ -> return ()
        modify' (\s -> s { cxScope = maybe (Map.delete n (cxScope s)) (\o -> Map.insert n o (cxScope s)) old })
        return r


-- EXPRESSIONS

-- | an expression in an owned position: it yields a count
owned :: MExpr -> CK ()
owned e =
  let cls = mRep e in
  case mNode e of
    MLit (LString _) -> bad "a string literal without a count in an owned position (not wrapped in Own)"
    MLit _ -> return ()
    MLocal n -> when (refClass cls) (consume n)
    MGlobal c ->
      do  cx <- get
          case Map.lookup c (cxClones cx) of
            Nothing -> bad "an unknown clone"
            Just d
              | mdKind d == Value -> when (refClass (mdResult d) || refClass cls) (bad "a global value without a count in an owned position (not wrapped in Own)")
              | null (Map.findWithDefault [] c (cxCaps cx)) -> bad "a static closure without a count in an owned position (not wrapped in Own)"
              | otherwise -> forM_ [ n | (n, cc) <- Map.findWithDefault [] c (cxCaps cx), refClass cc ] consume       -- the closure takes a count on each captured reference
    MKernel _ _ -> return ()
    MCtor _ _ _ -> when (refClass cls) (bad "a nullary constructor without a count in an owned position (not wrapped in Own)")
    MCall h args -> call e h args
    MLam _ _ -> bad "a lambda"
    MIf bs final -> ifChain bs final
    MLetVal n v b ->
      do  owned v
          withOwned n (mRep v) (owned b)
    MSeq a b ->
      do  when (refClass (mRep a)) (bad "the value of a sequence is a reference that is never consumed")
          owned a
          owned b
    MCase s bs -> caseOf s bs
    MAccess r _ _ ->
      do  when (refClass cls) (bad "a field access that yields a reference without a count (not wrapped in Own)")
          view r
    MUpdate _ _ -> bad "a record update"
    MRecord fs -> mapM_ (owned . snd) fs
    MTuple xs -> mapM_ owned xs
    MList xs -> mapM_ owned xs
    MDup vs b ->
      do  forM_ vs (\(n, c) -> when (refClass c) (addCount n))
          owned b
    MDrop vs b ->
      do  forM_ vs (\(n, c) -> when (refClass c) (consume n))
          owned b
    MOwn b -> view b


-- | an expression that only looks at something that stays alive (the argument of `MOwn`, a borrowed argument)
view :: MExpr -> CK ()
view e =
  case mNode e of
    MLit _ -> return ()
    MLocal n -> when (refClass (mRep e)) (borrow n)
    MGlobal _ -> return ()
    MKernel _ _ -> return ()
    MCtor _ _ _ -> return ()
    MAccess r _ _ -> view r
    MCall (MExpr _ (MKernel name _)) args | kernelResultBorrowed name -> kernelCallArgs name args
    _ -> bad "an expression in a position that only looks at a value (a borrowed argument must be a variable, a literal or a global)"


call :: MExpr -> MExpr -> [MExpr] -> CK ()
call e h args =
  case mNode h of
    MKernel name key ->
      do  when (kernelResultBorrowed name && refClass (mRep e)) (bad "a kernel result without a count in an owned position (not wrapped in Own)")
          unless (name `elem` ["elm/core:Basics.and", "elm/core:Basics.or"]) (kernelCallArgs' name key args)
          when (name `elem` ["elm/core:Basics.and", "elm/core:Basics.or"]) (bad "&& or || reached the checker (the pass makes them an if)")
    MCtor _ _ _ -> mapM_ owned args
    MGlobal c ->
      do  cx <- get
          case Map.lookup c (cxClones cx) of
            Just d | mdKind d == Function, length args == length (mdParams d) ->
              do  mapM_ owned args
                  forM_ [ n | (n, cc) <- Map.findWithDefault [] c (cxCaps cx), refClass cc ] borrow     -- the caller passes its variables, borrowed
            _ -> apply
    _ -> apply
  where
    apply =
      do  case mNode h of
            MLocal _ -> view h
            MGlobal _ -> view h
            _ -> bad "the function of a call of a function value is not a variable or a global"
          mapM_ owned args


kernelCallArgs :: String -> [MExpr] -> CK ()
kernelCallArgs name args = kernelCallArgs' name (Key []) args


kernelCallArgs' :: String -> Key -> [MExpr] -> CK ()
kernelCallArgs' name key args =
  case kernelSig name key of
    Nothing -> bad ("the kernel " ++ name ++ " has no signature")
    Just sig
      | length sig /= length args -> bad ("the kernel " ++ name ++ " has a signature of the wrong length")
      | otherwise ->
          do  zipWithM_ (\l a -> if not (refClass (mRep a)) then owned a else if l == 'o' then owned a else view a) sig args
              -- the borrowed variables must still be alive when the call happens (after the owned arguments have been consumed)
              forM_ [ n | (l, MExpr c (MLocal n)) <- zip sig args, l /= 'o', refClass c ] borrow


ifChain :: [(MExpr, MExpr)] -> MExpr -> CK ()
ifChain [] final = owned final
ifChain ((c, b) : rest) final =
  do  owned c
      s0 <- gets cxScope
      owned b
      s1 <- gets cxScope
      modify' (\s -> s { cxScope = s0 })
      ifChain rest final
      s2 <- gets cxScope
      agree s1 s2
      -- s2 stays as the state after the whole if


-- | two paths must leave every variable with the same number of counts
agree :: Scope -> Scope -> CK ()
agree a b =
  forM_ (Map.toList a) $ \(n, v) ->
    case Map.lookup n b of
      Just w | vCount w /= vCount v -> bad ("variable " ++ n ++ " has " ++ show (vCount v) ++ " count(s) after one branch and " ++ show (vCount w) ++ " after another")
      _ -> return ()


caseOf :: MExpr -> [(MPat, MExpr)] -> CK ()
caseOf s bs =
  do  case mNode s of
        MLocal n | refClass (mRep s) -> borrow n
        _ | refClass (mRep s) -> bad "the scrutinee of a case is not a variable"
        _ -> owned s
      let root = case mNode s of { MLocal n -> Just n; _ -> Nothing }
      s0 <- gets cxScope
      results <-
        mapM (\(p, b) ->
                do  modify' (\st -> st { cxScope = s0 })
                    let binders = [ n | (n, c) <- patBinders p, refClass c ]
                    forM_ binders (\n -> modify' (\st -> st { cxScope = Map.insert n (V False 0 root) (cxScope st) }))
                    owned b
                    forM_ binders $ \n ->
                      do  v <- gets (Map.lookup n . cxScope)
                          case v of
                            Just x | vCount x /= 0 -> bad ("pattern variable " ++ n ++ " has " ++ show (vCount x) ++ " count(s) left at the end of its branch")
                            _ -> return ()
                    modify' (\st -> st { cxScope = foldr Map.delete (cxScope st) binders })
                    gets cxScope)
             bs
      case results of
        [] -> return ()
        r : rest ->
          do  mapM_ (agree r) rest
              put' r
  where
    put' sc = modify' (\st -> st { cxScope = sc })
