{-# OPTIONS_GHC -Wall #-}
module Ficcus.Mono.Free
  ( captures
  , patVars
  , patBinders
  , freeVars
  , refClass
  )
  where


-- Ficcus, stage (iv): free variables of Mono expressions, shared by the C generator and the Rc pass.


import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import Ficcus.Mono.Class
import Ficcus.Mono.Ir
import Ficcus.Mono.Layout (nptrOf)


-- | does a value of this class hold counted references (the class is a reference or a struct with a reference component)?
refClass :: Class -> Bool
refClass c = nptrOf [c] > 0


-- CAPTURED VARIABLES OF LIFTED FUNCTIONS


-- the local variables a lifted clone uses from its owner, directly or through the lifted clones it calls
captures :: [MDef] -> Map.Map CloneId [(String, Class)]
captures clones =
  fixpoint (Map.fromList [ (mdClone d, if mdLifted d == Nothing then Map.empty else Map.map id (freeOf d)) | d <- clones ])
  where
    byId = Map.fromList [ (mdClone d, d) | d <- clones ]
    freeOf d =
      let (used, bound) = maybe (Map.empty, Set.empty) locals (mdBody d)
          own = Set.union bound (Set.fromList (map fst (mdParams d)))
      in Map.filterWithKey (\k _ -> not (Set.member k own)) used
    fixpoint m =
      let step = Map.mapWithKey (\c cur -> grow c cur) m
          grow c cur =
            case Map.lookup c byId of
              Nothing -> cur
              Just d ->
                let own = Set.union (maybe Set.empty (snd . locals) (mdBody d)) (Set.fromList (map fst (mdParams d)))
                    viaCallees = Map.unions [ Map.filterWithKey (\k _ -> not (Set.member k own)) (Map.findWithDefault Map.empty r m)
                                            | r <- maybe [] exprRefs (mdBody d), r /= c ]
                in Map.union cur viaCallees
      in if step == m then Map.map Map.toList m else fixpoint step
    locals :: MExpr -> (Map.Map String Class, Set.Set String)
    locals e =
      let here = case mNode e of
            MLocal n -> (Map.singleton n (mRep e), Set.empty)
            MLetVal n _ _ -> (Map.empty, Set.singleton n)
            MCase _ bs -> (Map.empty, Set.fromList (concatMap (patVars . fst) bs))
            _ -> (Map.empty, Set.empty)
          below = map locals (children e)
      in (Map.unions (fst here : map fst below), Set.unions (snd here : map snd below))



-- the variables a pattern binds
patVars :: MPat -> [String]
patVars (MPat _ n) =
  case n of
    PVar v -> [v]
    PCtor _ _ ps -> concatMap patVars ps
    PTuple ps -> concatMap patVars ps
    PCons a b -> patVars a ++ patVars b
    PAlias p v -> v : patVars p
    PRecord fs -> [ v | (_, v, _) <- fs ]
    _ -> []





-- | the variables a pattern binds, with their classes
patBinders :: MPat -> [(String, Class)]
patBinders (MPat c n) =
  case n of
    PVar v -> [(v, c)]
    PCtor _ _ ps -> concatMap patBinders ps
    PTuple ps -> concatMap patBinders ps
    PCons a b -> patBinders a ++ patBinders b
    PAlias p v -> (v, c) : patBinders p
    PRecord fs -> [ (v, fc) | (_, v, fc) <- fs ]
    _ -> []


-- | the local variables an expression uses, with their classes: the variables it names, and the captured variables of every lifted
-- clone it refers to (a call of a lifted function passes them, a closure of it stores them). `caps` is the result of `captures`.
freeVars :: Map.Map CloneId [(String, Class)] -> MExpr -> Map.Map String Class
freeVars caps = go
  where
    go e =
      case mNode e of
        MLocal n -> Map.singleton n (mRep e)
        MGlobal c -> Map.fromList (Map.findWithDefault [] c caps)
        MLetVal n v b -> Map.union (go v) (Map.delete n (go b))
        MCase s bs -> Map.unions (go s : [ foldr (Map.delete . fst) (go b) (patBinders p) | (p, b) <- bs ])
        MLam ps b -> foldr (Map.delete . fst) (go b) ps
        _ -> Map.unions (map go (children e))
