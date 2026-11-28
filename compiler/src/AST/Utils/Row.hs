-- Substituting a record type for the extension variable of a record (Ficus track D10).
-- `dealias` used to leave the extension variable of `{ r | x : Int }` alone when `r` was bound to a
-- type argument (elm/compiler TODO "record extensions seem to be skipped during dealiasing"), so
-- an unbound variable remained (case 1916).
module AST.Utils.Row
  ( extend
  , mergeField
  )
  where


import Control.Monad (zipWithM)
import qualified Data.Map as Map
import Data.Maybe (fromMaybe)

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
      -- a field that both have (D10, option B): one field, the types having been merged
      TRecord (Map.unionWithKey (\_ own (FieldType _ more) -> sameField own more) fields (Map.map shift moreFields)) maybeExt

    _ ->
      TRecord fields (Just var)

  where
    sameField (FieldType i t1) t2 =
      FieldType i (fromMaybe t1 (mergeField expand t1 t2))


-- | The one type of a field that is given twice, if the two types can be the same type: a type
-- variable stands for any type. Nothing when they differ.
mergeField :: (Type -> Type) -> Type -> Type -> Maybe Type
mergeField expand =
  go
  where
    go a b =
      case (a, b) of
        (TVar _, t) -> Just t
        (t, TVar _) -> Just t
        (TAlias {}, _) -> go (expand a) b
        (_, TAlias {}) -> go a (expand b)
        (TLambda a1 a2, TLambda b1 b2) -> TLambda <$> go a1 b1 <*> go a2 b2
        (TType h n as, TType h2 n2 bs)
          | h == h2 && n == n2 && length as == length bs -> TType h n <$> zipWithM go as bs
        (TUnit, TUnit) -> Just TUnit
        (TPair a1 a2, TPair b1 b2) -> TPair <$> go a1 b1 <*> go a2 b2
        (TTriple a1 a2 a3, TTriple b1 b2 b3) -> TTriple <$> go a1 b1 <*> go a2 b2 <*> go a3 b3
        (TRecord fs1 e1, TRecord fs2 e2)
          | Map.keysSet fs1 == Map.keysSet fs2 ->
              do  fs <- sequence (Map.intersectionWith (\(FieldType i x) (FieldType _ y) -> FieldType i <$> go x y) fs1 fs2)
                  ext <- case (e1, e2) of
                    (Nothing, Nothing) -> Just Nothing
                    (Just v, Just _) -> Just (Just v)
                    _ -> Nothing
                  Just (TRecord fs ext)
        _ -> Nothing
