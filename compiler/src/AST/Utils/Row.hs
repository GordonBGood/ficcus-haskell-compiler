-- Substituting a record type for the extension variable of a record (Ficcus track D10).
-- `dealias` used to leave the extension variable of `{ r | x : Int }` alone when `r` was bound to a
-- type argument (elm/compiler TODO "record extensions seem to be skipped during dealiasing"), so
-- an unbound variable remained (case 1916).
module AST.Utils.Row
  ( extend
  )
  where


import qualified Data.Map as Map

import AST.Canonical (Type(..), FieldType(..))
import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeVar as T


-- | `{ r | fields }` where `r` is bound to `arg`. `expand` removes the aliases at the head of `arg`.
-- Any other type is left as the variable `r` (the kind check refuses such programs earlier).
extend :: (Type -> Type) -> Map.Map N.Name FieldType -> T.Var -> Type -> Type
extend expand fields var arg =
  case expand arg of
    TVar v ->
      TRecord fields (Just v)

    TRecord moreFields maybeExt ->
      -- the fields of the argument come after the own ones
      let
        offset = 1 + maximum (0 : [ fromIntegral i | FieldType i _ <- Map.elems fields ]) :: Int
        shift (FieldType i t) = FieldType (i + fromIntegral offset) t
      in
      TRecord (Map.union fields (Map.map shift moreFields)) maybeExt

    _ ->
      TRecord fields (Just var)
