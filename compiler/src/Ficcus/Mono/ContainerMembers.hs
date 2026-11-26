{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE PatternGuards #-}
module Ficcus.Mono.ContainerMembers
  ( membersInside
  , MemberTable
  )
  where


-- Ficcus (A3b, docs/A3B-PLAN.md section 2): members inside containers.
--
-- `==` and the comparisons at an exact type that holds a custom type with its own `eq` or `compare` member (a list, tuple,
-- record, `Maybe`, `Dict`, `Array`, `Vector`, or a custom type with such a type in a field) are the structural helpers of the
-- C generator (`CGen.eqExpr`, `cmpExpr`), which call the member wherever the type with the member appears inside.  This
-- module finds those types: the specializer requests the clone of the member of each (at its exact type) and hands the table
-- `(member, exact type) -> clone` to the C generator in `MProgram` (`mpMembers`).


import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import Ficcus.Mono.Class (MType(..))
import Ficcus.Mono.Ir (CloneId, UnionShape(..))


-- | the clones of the members called by the structural helpers, by member name and exact type of the subject
type MemberTable = Map.Map (String, MType) CloneId


-- | every exact type inside `t0` (its type arguments, tuple and record parts, and the constructor fields of custom types with
-- the arguments put in) for which `has` says it has the member, in the order found, each once.  A type with the member is
-- not entered (its own member is called, and it compares its own fields).  `skip` types are scalars of the C generator (the
-- sized integers): not entered.  Every exact type is entered once, so a regular recursive type ends; a type that keeps
-- growing (non-regular recursion) stops at `limit` exact types with Left.
membersInside :: (String -> Bool) -> (String -> Bool) -> Map.Map String UnionShape -> MType -> Either String [MType]
membersInside has skip unions t0 =
  case go (Set.empty, []) [t0] of
    Left why -> Left why
    Right (_, found) -> Right (reverse found)
  where
    limit = 2000 :: Int

    go acc [] = Right acc
    go (seen, found) (t : rest)
      | Set.member t seen = go (seen, found) rest
      | Set.size seen > limit = Left ("the type " ++ show t0 ++ " holds more than " ++ show limit ++ " different types (a type used at another argument inside itself)")
      | otherwise =
          let seen' = Set.insert t seen in
          case t of
            TyCon tid args
              | skip tid -> go (seen', found) rest
              | has tid -> go (seen', t : found) rest
              | otherwise ->
                  let fields = maybe [] (\u -> [ subst args f | (_, _, fs) <- usCtors u, f <- fs ]) (Map.lookup tid unions)
                  in go (seen', found) (args ++ fields ++ rest)
            TyTuple xs -> go (seen', found) (xs ++ rest)
            TyRecord fs -> go (seen', found) (map snd fs ++ rest)
            TyFun _ _ -> go (seen', found) rest
            TyUnit -> go (seen', found) rest

    -- the parameters of a union are `TyCon "#i" []`
    subst args ty =
      case ty of
        TyCon ('#' : ds) [] | [(i, "")] <- reads ds, i < length args -> args !! i
        TyCon c xs -> TyCon c (map (subst args) xs)
        TyFun a b -> TyFun (subst args a) (subst args b)
        TyRecord fs -> TyRecord [ (f, subst args x) | (f, x) <- fs ]
        TyTuple xs -> TyTuple (map (subst args) xs)
        TyUnit -> TyUnit
