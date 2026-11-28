{-# LANGUAGE PatternGuards #-}
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
-- ids AND by the overlay marker (E3c review M1): the type's interface, among the module's imports, has the marker as its only
-- constructor (`FicInt8Builtin`, `FicVectorBuiltin`; Ficcus.Mono.Sized.sizedEnabled checks the same). A project module of the
-- same name (it wins over the overlay) has no marker, so its type gets Elm's payload error, as any custom type; so does an overlay
-- type whose module the port module does not import (only reached through an alias of another module: its interface is not here).
-- This check is the only gate: Ficcus.Mono.PortFic recognizes the ids alone, and flags keep Elm's check (Optimize.Module).
-- Custom types and `Dict` stay refused, with Elm's error.
--
-- Build.compile decides which check a module gets: this one when the file is `.fic` and the build is to C (or `.mono`). A build to
-- JavaScript has no overlay modules, so a `.fic` program with a Ficcus payload is refused there by its import of `Int8` or `Vector`
-- (D6: the JS build of such a program is refused), or, for a project module of that name, by Elm's payload error.


import qualified Data.Foldable as F
import qualified Data.Map as Map

import qualified AST.Canonical as Can
import qualified AST.Members as Members
import qualified AST.Utils.Type as Type
import qualified Canonicalize.Effects as Effects
import qualified AST.Prim.Module as Module
import qualified AST.Prim.Name as N
import qualified Elm.Interface as I
import qualified Elm.ModuleName as ModuleName
import qualified Elm.Package as Pkg
import qualified AST.Prim.TypeName as T
import qualified Reporting.Error.Canonicalize as Error



-- | the payload check of a module: Elm's when the flag is False; the interfaces are the module's imports
checkPayload :: Bool -> Map.Map Module.Name I.Interface -> Can.Type -> Either (Can.Type, Error.InvalidPayload) ()
checkPayload ficPayloads ifaces =
  if ficPayloads then check (overlayIds ifaces) else Effects.checkPayload


-- | the ids of the Ficcus payload types whose module among the imports is the overlay's (its type has the marker constructor)
overlayIds :: Map.Map Module.Name I.Interface -> [String]
overlayIds ifaces =
  [ tid
  | (m, iface) <- Map.toList ifaces
  , Pkg.toChars (I._home iface) == "author/project"
  , let s = Module.toChars m
  , let tid = "author/project:" ++ s ++ "." ++ s
  , tid `elem` vectorId : sizedIds
  , (t, u) <- Map.toList (I._unions iface)
  , T.nameToChars t == s
  , [ N.toChars c | Can.Ctor c _ _ _ <- Can._u_alts (unionOf u) ] == ["Fic" ++ s ++ "Builtin"]
  ]
  where
    unionOf u = case u of { I.OpenUnion x -> x; I.ClosedUnion x -> x; I.PrivateUnion x -> x }


-- Elm's walk (Canonicalize.Effects.checkPayload) with the overlay's Ficcus types accepted; every refusal is the one Elm's walk gives
check :: [String] -> Can.Type -> Either (Can.Type, Error.InvalidPayload) ()
check overlay tipe =
  case tipe of
    Can.TAlias _ _ args aliasedType ->
      check overlay (Type.dealias args aliasedType)

    Can.TType home name args
      | [] <- args, tid `elem` sizedIds, tid `elem` overlay -> Right ()
      | [arg] <- args, tid == vectorId, tid `elem` overlay -> check overlay arg
      | otherwise ->
          case Effects.checkPayload (Can.TType home name (map (const Can.TUnit) args)) of
            Right () -> F.traverse_ (check overlay) args       -- Json.Value, String, Int, Float, Bool, List, Maybe, Array
            Left _ -> Effects.checkPayload tipe                -- Elm's error for this type
      where
        tid = ficcusId home name

    Can.TPair a b -> check overlay a *> check overlay b
    Can.TTriple a b c -> check overlay a *> check overlay b *> check overlay c
    Can.TRecord fields Nothing -> F.traverse_ (\(Can.FieldType _ t) -> check overlay t) fields
    _ -> Effects.checkPayload tipe


-- | Optimize.Port: the Elm type a Ficcus payload type is converted like in the (unused) JavaScript converters of a build to C, so
-- that the optimizer does not stop on it (a sized integer is an Int, `Float32` a Float, `Vector a` an `Array a`).
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
  [ "author/project:Float32.Float32" ]


vectorId :: String
vectorId =
  "author/project:Vector.Vector"

