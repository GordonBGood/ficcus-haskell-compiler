{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE PatternGuards #-}
module Ficcus.Mono.ModelUnpack
  ( unpackModel
  )
  where


-- Ficcus, effects slice E1 step 3 (docs/EFFECTS-DESIGN.md D-fx-3 amended): the fields of the model, taken apart at the entry of `update`.
--
-- The seed (Ficcus.Mono.Program.modelSeeds) makes `update`'s model parameter owned, and the typed stepper moves the model into it. But
-- the Rc pass reads a field of an owned struct variable as a VIEW plus a count of its own, and drops the struct's leaves only after
-- the variable's last use: in `{ m | a = Array.set k v m.a, n = m.n - 1 }` the array has two counts while `set` runs (the field read
-- and `m` itself, which `m.n` still uses), so every step copies it (G17b: 2 copies per step without this pass). A field bound by a
-- `let` before anything else is an owned variable of its own, and `m` is dead after the bindings where nothing uses it whole, so the
-- leaves are unique when they reach the update kernels.
--
-- The rewrite, on the `update` clone of the program shape only (a struct model with reference leaves): every field that the body
-- reads directly from the parameter (`MAccess (MLocal m) f i`, not under a binder that shadows `m`) is bound once at the entry,
--
--   update msg m = body        ==>        update msg m = let m$a = m.a in let m$d = m.d in ... body[m.f := m$f]
--
-- Field reads are pure, so the result is the same. A use of the whole `m` (returned unchanged, captured by a lambda) is kept: it holds
-- the leaves as before, and only on that path. Not done: helpers that `update` passes the model to (the same Rc limitation; the
-- general fix is a per-leaf move in the Rc pass). FICCUS_NO_MODEL_UNPACK=1 switches it off (G17b shows the copies).
--
-- The record update `{ m | a = e }` is lowered by Spec to `let _upK = m in { a = e, d = _upK.d }`: `_upK` would hold a count on every
-- leaf while `e` runs (docs/E1-REVIEW.md Q1, R1Partial: 2 copies per step). Where `_upK` is only read field by field, it is `m` itself:
-- its reads become reads of `m` and the `let` goes (dealias), before the fields are bound.


import qualified Data.List as List
import qualified Data.Map.Strict as Map
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)

import Ficcus.Mono.Class
import Ficcus.Mono.Free (refClass)
import Ficcus.Mono.Ir
import Ficcus.Mono.Program (Shape(..), programShape)


{-# NOINLINE noUnpack #-}
noUnpack :: Bool
noUnpack = unsafePerformIO (fmap (== Just "1") (lookupEnv "FICCUS_NO_MODEL_UNPACK"))


unpackModel :: MProgram -> MProgram
unpackModel prog
  | noUnpack = prog
  | otherwise =
      case programShape (mpMain prog) (Map.fromList [ (mdClone d, d) | d <- mpClones prog ]) >>= shStep of
        Just (ud, _) -> prog { mpClones = map (\d -> if mdClone d == mdClone ud then unpackDef d else d) (mpClones prog) }
        Nothing -> prog


unpackDef :: MDef -> MDef
unpackDef d =
  case (mdParams d, mdBody d) of
    ([_, (m, mc@(CStruct _))], Just body) | refClass mc ->
      let fields = List.nubBy (\(_, i, _) (_, j, _) -> i == j) (List.sortOn (\(_, i, _) -> i) (reads' m body0))
          var i = "_mf" ++ show i ++ "_" ++ m
          body0 = dealias m body
          body' = substAccess m (\a -> MExpr (mRep a) (MLocal (var (accessPos a)))) body0
          wrap (f, i, c) acc = MExpr (mRep acc) (MLetVal (var i) (MExpr c (MAccess (MExpr mc (MLocal m)) f i)) acc)
      in if null fields then d else d { mdBody = Just (foldr wrap body' fields) }
    _ -> d
  where
    accessPos a = case mNode a of { MAccess _ _ i -> i; _ -> -1 }


-- `let _upK = m in b` (a record update of m), where b reads _upK only field by field and does not rebind m: b with _upK.f := m.f
dealias :: String -> MExpr -> MExpr
dealias m e =
  case mNode e of
    MLetVal t v@(MExpr _ (MLocal n)) b
      | n == m, "_up" `List.isPrefixOf` t, t /= m, not (bareUse t b), not (rebinds m b) ->
          dealias m (substAccess t (\a -> case mNode a of { MAccess _ f i -> MExpr (mRep a) (MAccess v f i); _ -> a }) b)
    _ -> descend m (dealias m) e


-- t used other than as the record of a field read
bareUse :: String -> MExpr -> Bool
bareUse t e =
  case mNode e of
    MAccess (MExpr _ (MLocal n)) _ _ | n == t -> False
    MLocal n -> n == t
    _ -> any (bareUse t) (children e)


rebinds :: String -> MExpr -> Bool
rebinds m e = shadows m e || any (rebinds m) (children e)


-- the fields read directly from `m` (name, position, class), outside binders that shadow it
reads' :: String -> MExpr -> [(String, Int, Class)]
reads' m e =
  case mNode e of
    MAccess (MExpr _ (MLocal n)) f i | n == m -> [(f, i, mRep e)]
    _ | shadows m e -> concat [ reads' m c | c <- unshadowed m e ]
      | otherwise -> concatMap (reads' m) (children e)


-- every read of a field of m (outside binders that shadow it) replaced by `new` of the read
substAccess :: String -> (MExpr -> MExpr) -> MExpr -> MExpr
substAccess m new e =
  case mNode e of
    MAccess (MExpr _ (MLocal n)) _ _ | n == m -> new e
    _ -> descend m (substAccess m new) e


-- go on the children of an expression where m is still the parameter (a binder of m keeps its scope unchanged)
descend :: String -> (MExpr -> MExpr) -> MExpr -> MExpr
descend m go x@(MExpr c node) =
      case node of
        MCall f args -> MExpr c (MCall (go f) (map go args))
        MLam ps b | m `elem` map fst ps -> x
                  | otherwise -> MExpr c (MLam ps (go b))
        MIf bs f -> MExpr c (MIf [ (go a, go b) | (a, b) <- bs ] (go f))
        MLetVal n v b | n == m -> MExpr c (MLetVal n (go v) b)
                      | otherwise -> MExpr c (MLetVal n (go v) (go b))
        MSeq a b -> MExpr c (MSeq (go a) (go b))
        MCase s bs -> MExpr c (MCase (go s) [ (p, if m `elem` map fst (patVars p) then b else go b) | (p, b) <- bs ])
        MAccess r f i -> MExpr c (MAccess (go r) f i)
        MUpdate r fs -> MExpr c (MUpdate (go r) [ (f, go v) | (f, v) <- fs ])
        MRecord fs -> MExpr c (MRecord [ (f, go v) | (f, v) <- fs ])
        MTuple xs -> MExpr c (MTuple (map go xs))
        MList xs -> MExpr c (MList (map go xs))
        _ -> x        -- leaves; the Rc nodes do not exist yet (the pass runs before Rc)


-- a node that binds `m` in some of its children, and the children where `m` is still the parameter
shadows :: String -> MExpr -> Bool
shadows m e =
  case mNode e of
    MLam ps _ -> m `elem` map fst ps
    MLetVal n _ _ -> n == m
    MCase _ bs -> any (\(p, _) -> m `elem` map fst (patVars p)) bs
    _ -> False


unshadowed :: String -> MExpr -> [MExpr]
unshadowed m e =
  case mNode e of
    MLam _ _ -> []
    MLetVal _ v _ -> [v]
    MCase s bs -> s : [ b | (p, b) <- bs, m `notElem` map fst (patVars p) ]
    _ -> children e


patVars :: MPat -> [(String, Class)]
patVars p =
  case mpNode p of
    PVar n -> [(n, mpRep p)]
    PCtor _ _ ps -> concatMap patVars ps
    PRecord fs -> [ (n, c) | (_, n, c) <- fs ]
    PTuple ps -> concatMap patVars ps
    PCons a b -> patVars a ++ patVars b
    PAlias q n -> (n, mpRep p) : patVars q
    _ -> []
