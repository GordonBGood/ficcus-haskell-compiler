{-# LANGUAGE PatternGuards #-}
-- | (P1) the field types of a custom type at an exact type.
--
-- A union shape (`Ir.UnionShape`) writes the i-th type parameter as `TyCon "#i" []`. A field that is an extensible record
-- `{ r | x : Int }` keeps its row as a slot `("#row", TyCon "#i" [])` in the field list (`Modules.canToM`): no Elm field
-- can be named `#row`. Putting in the arguments of the exact type fills the slot: a closed record row adds its fields (the
-- result is in Elm's `Name` order, the same `MType` as the record's own type); any other row is dropped.
module Ficus.Mono.RowShape
  ( rowSlot
  , substShape
  )
  where


import qualified Data.List as List

import qualified AST.Prim.Name as N
import qualified String as S
import Ficus.Mono.Class (MType(..))


-- | the name of the slot that holds the row variable of an extensible record field
rowSlot :: String
rowSlot = "#row"


-- | a field type of a union shape with the arguments of the exact type put in
substShape :: [MType] -> MType -> MType
substShape args ty =
  case ty of
    TyCon ('#' : ds) [] | [(i, "")] <- reads ds, i < length args -> args !! i
    TyCon c xs -> TyCon c (map go xs)
    TyFun a b -> TyFun (go a) (go b)
    TyRecord fs ->
      let (rows, own) = List.partition ((== rowSlot) . fst) fs
          own' = [ (f, go x) | (f, x) <- own ]
          extra = concat [ rs | (_, r) <- rows, TyRecord rs <- [go r] ]
      in if null rows then TyRecord own' else TyRecord (List.sortOn (nameOrder . fst) (own' ++ extra))
    TyTuple xs -> TyTuple (map go xs)
    TyUnit -> TyUnit
  where
    go = substShape args


-- the order of a record's fields: Elm's `Name` order (Map.toList of the canonical fields), which is also the struct layout
-- and the order `Debug.toString` prints (shorter names first)
nameOrder :: String -> N.Name
nameOrder = N.fromString . S.fromChars
