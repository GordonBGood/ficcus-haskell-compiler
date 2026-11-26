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
  , subExprs
  , substitute
  , typeVarNames
  )
  where


import qualified Data.Map.Strict as Map

import qualified AST.Canonical as Can
import qualified Reporting.Annotation as A
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


-- | (A5b) replace variables by types
substitute :: Map.Map String TType -> TType -> TType
substitute =
  subst


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



-- | every node of an expression (the expression itself first), into `let` definitions and lambdas; the specializer's
-- walk over a clone's body for the variables its constrained calls decide (Spec.deadByMembers)
subExprs :: Can.Expr -> [Can.Expr]
subExprs expr@(A.At _ e) =
  expr :
    case e of
      Can.List xs -> concatMap subExprs xs
      Can.Negate x -> subExprs x
      Can.Binop _ _ _ _ l r -> subExprs l ++ subExprs r
      Can.Lambda _ x -> subExprs x
      Can.Call f xs -> concatMap subExprs (f : xs)
      Can.If branches final -> concat [ subExprs c ++ subExprs b | (c, b) <- branches ] ++ subExprs final
      Can.Let def body -> defBody def ++ subExprs body
      Can.LetRec defs body -> concatMap defBody defs ++ subExprs body
      Can.LetDestruct _ x body -> subExprs x ++ subExprs body
      Can.Case x branches -> subExprs x ++ concat [ subExprs b | Can.CaseBranch _ b <- branches ]
      Can.Access x _ -> subExprs x
      Can.Update _ x fields -> subExprs x ++ concat [ subExprs b | Can.FieldUpdate _ b <- Map.elems fields ]
      Can.Record fields -> concatMap subExprs (Map.elems fields)
      Can.Pair a b -> subExprs a ++ subExprs b
      Can.Triple a b c -> subExprs a ++ subExprs b ++ subExprs c
      _ -> []
  where
    defBody def =
      case def of
        Can.Def _ _ body -> subExprs body
        Can.TypedDef _ _ _ body _ -> subExprs body


-- | (A5f) the names of the type variables of a type
typeVarNames :: TType -> [String]
typeVarNames t =
  case t of
    TCon _ _ args -> concatMap typeVarNames args
    TFun a b -> typeVarNames a ++ typeVarNames b
    TRecord fields ext -> concatMap typeVarNames (Map.elems fields) ++ maybe [] typeVarNames ext
    TPair a b -> typeVarNames a ++ typeVarNames b
    TTriple a b c -> typeVarNames a ++ typeVarNames b ++ typeVarNames c
    TVar n _ _ -> [n]
    TAlias _ _ args real -> concatMap (typeVarNames . snd) args ++ typeVarNames real
    _ -> []
