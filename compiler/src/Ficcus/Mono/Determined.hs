{-# OPTIONS_GHC -Wall #-}
-- Ficcus (A5a, D2): variables of a constraint that its subject determines (docs/A5-INFERENCE-DESIGN.md section 1, rule 3).
--
--     describe : a -> String
--         where
--             a has f : a -> z
--
-- `z` is not in the type of `describe`, so the type at a use does not give it; the member does.  At a use with `a := T`,
-- the member `T.f : T -> Int` decides `z := Int`.  The specializer keys the clone of `describe` with it (Spec.viaClone),
-- so the clone's hidden member and the nodes of type `z` in its body get the exact type.
module Ficcus.Mono.Determined
  ( fill
  )
  where


import qualified Data.Map.Strict as Map

import Type.Readout (TType(..))


-- | the types of the holes of a constraint's member type (variables `isHole` says are not known at the use), read off
-- the member's own type: the constraint type (with what is known substituted) is walked beside the member's type; a
-- variable of the member is bound to the part of the constraint type it meets, a hole to the part of the member type
-- it meets, with the member's variables replaced
fill :: (String -> Bool) -> TType -> TType -> Map.Map String TType
fill isHole constraint member =
  let (holes, binds) = go constraint member (Map.empty, Map.empty)
  in Map.map (subst binds) holes
  where
    go c m acc@(hs, bs) =
      case (c, m) of
        (TAlias _ _ _ real, _) -> go real m acc
        (_, TAlias _ _ _ real) -> go c real acc
        (TVar n _ _, _) | isHole n -> (Map.insertWith (\_ old -> old) n m hs, bs)
        (_, TVar v _ _) -> (hs, Map.insertWith (\_ old -> old) v c bs)
        (TCon h1 n1 as, TCon h2 n2 bs') | h1 == h2 && n1 == n2 && length as == length bs' -> goAll (zip as bs') acc
        (TFun a b, TFun x y) -> goAll [(a, x), (b, y)] acc
        (TPair a b, TPair x y) -> goAll [(a, x), (b, y)] acc
        (TTriple a b d, TTriple x y z) -> goAll [(a, x), (b, y), (d, z)] acc
        (TRecord f1 _, TRecord f2 _) -> goAll (Map.elems (Map.intersectionWith (,) f1 f2)) acc
        _ -> acc

    goAll pairs acc =
      foldl (\a (x, y) -> go x y a) acc pairs


subst :: Map.Map String TType -> TType -> TType
subst s t =
  case t of
    TCon h n args -> TCon h n (map go args)
    TFun a b -> TFun (go a) (go b)
    TRecord fields ext -> TRecord (Map.map go fields) (fmap go ext)
    TUnit -> t
    TPair a b -> TPair (go a) (go b)
    TTriple a b c -> TTriple (go a) (go b) (go c)
    TVar n _ _ -> Map.findWithDefault t n s
    TAlias h n args real -> TAlias h n [ (v, go x) | (v, x) <- args ] (go real)
    TRef _ -> t
    TError -> t
  where
    go = subst s
