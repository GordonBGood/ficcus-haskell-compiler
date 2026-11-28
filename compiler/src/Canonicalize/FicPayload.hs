{-# OPTIONS_GHC -Wall #-}
module Canonicalize.FicPayload
  ( checkPayload
  , elmLike
  )
  where


-- Ficcus, effects slice E3c (docs/E3-PORTS-DESIGN.md D6): the payload types of a port in a `.fic` module of a build to C.
--
-- Elm's set (Canonicalize.Effects.checkPayload, unchanged and still the check of every `.elm` module and of every build to
-- JavaScript) plus the types of Ficcus: the sized integers `Int8 Int16 Int32 Word8 Word16 Word32 Word64`, `Float32`, and `Vector a`
-- of any payload type `a`. They are the overlay's types (overlay/*.elm, compiled as modules of the project), recognized by their
-- ids as Canonicalize.Derive does; a project module of the same name that wins over the overlay is refused later by the C
-- generator (its type is not the built-in one). Custom types and `Dict` stay refused, with Elm's error.
--
-- Build.compile decides which check a module gets: this one when the file is `.fic` and the build is to C (or `.mono`). A build to
-- JavaScript has no overlay modules, so a `.fic` program with a Ficcus payload is refused there by its import of `Int8` or `Vector`
-- (D6: the JS build of such a program is refused), or, for a project module of that name, by Elm's payload error.


import qualified Data.Foldable as F

import qualified AST.Canonical as Can
import qualified AST.Members as Members
import qualified AST.Utils.Type as Type
import qualified Canonicalize.Effects as Effects
import qualified Elm.ModuleName as ModuleName
import qualified AST.Prim.TypeName as T
import qualified Reporting.Error.Canonicalize as Error



-- | the payload check of a module: Elm's when the flag is False
checkPayload :: Bool -> Can.Type -> Either (Can.Type, Error.InvalidPayload) ()
checkPayload ficPayloads tipe =
  if ficPayloads then check tipe else Effects.checkPayload tipe


-- Elm's walk (Canonicalize.Effects.checkPayload) with the Ficcus types accepted; every refusal is the one Elm's walk gives
check :: Can.Type -> Either (Can.Type, Error.InvalidPayload) ()
check tipe =
  case tipe of
    Can.TAlias _ _ args aliasedType ->
      check (Type.dealias args aliasedType)

    Can.TType home name args
      | [] <- args, ficcusId home name `elem` sizedIds -> Right ()
      | [arg] <- args, ficcusId home name == vectorId -> check arg
      | otherwise ->
          case Effects.checkPayload (Can.TType home name (map (const Can.TUnit) args)) of
            Right () -> F.traverse_ check args       -- Json.Value, String, Int, Float, Bool, List, Maybe, Array: the arguments
            Left _ -> Effects.checkPayload tipe      -- Elm's error for this type

    Can.TPair a b -> check a *> check b
    Can.TTriple a b c -> check a *> check b *> check c
    Can.TRecord fields Nothing -> F.traverse_ (\(Can.FieldType _ t) -> check t) fields
    _ -> Effects.checkPayload tipe


-- | Optimize.Port: the Elm type a Ficcus payload type is converted like in the (unused) JavaScript converters of a build to C, so
-- that the optimizer does not stop on it (a sized integer is an Int, `Word64` and `Float32` a Float, `Vector a` an `Array a`).
-- Nothing for every other type.
elmLike :: ModuleName.Canonical -> T.Name -> [Can.Type] -> Maybe Can.Type
elmLike home name args =
  case args of
    []
      | tid `elem` floatIds -> Just (Can.TType ModuleName.basics T.float [])
      | tid `elem` sizedIds -> Just (Can.TType ModuleName.basics T.int [])
    [arg]
      | tid == vectorId -> Just (Can.TType ModuleName.array T.array [arg])
    _ -> Nothing
  where
    tid = ficcusId home name


ficcusId :: ModuleName.Canonical -> T.Name -> String
ficcusId = Members.typeId


sizedIds :: [String]
sizedIds =
  [ "author/project:" ++ s ++ "." ++ s | s <- ["Int8", "Int16", "Int32", "Word8", "Word16", "Word32", "Word64", "Float32"] ]


floatIds :: [String]
floatIds =
  [ "author/project:Word64.Word64", "author/project:Float32.Float32" ]


vectorId :: String
vectorId =
  "author/project:Vector.Vector"

