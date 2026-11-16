{-# OPTIONS_GHC -Wall -fno-warn-unused-do-bind #-}
module Compile
  ( Artifacts(..)
  , compile
  , compileTyped
  )
  where


import qualified Data.Map as Map
import qualified Data.NonEmptyList as NE

import qualified AST.Source as Src
import qualified AST.Canonical as Can
import qualified AST.Optimized as Opt
import qualified AST.Prim.Module as Module
import qualified AST.Prim.Name as N
import qualified Canonicalize.Module as Canonicalize
import qualified Elm.Interface as I
import qualified Elm.Package as Pkg
import qualified Nitpick.PatternMatches as PatternMatches
import qualified Optimize.Module as Optimize
import qualified Reporting.Error as E
import qualified Reporting.Error.Type as Error
import qualified Reporting.Result as R
import qualified Reporting.Render.Type.Localizer as Localizer
import qualified Type.Constrain.Module as Type
import qualified Type.Members as Members
import qualified Type.Readout as Readout
import qualified Type.Recorder as Recorder
import qualified Type.Solve as Type

import System.IO.Unsafe (unsafePerformIO)



-- COMPILE


data Artifacts =
  Artifacts
    { _modul :: Can.Module
    , _types :: Map.Map N.Name Can.Annotation
    , _graph :: Opt.LocalGraph
    }


compile :: Pkg.Name -> Map.Map Module.Name I.Interface -> Src.Module -> Either E.Error Artifacts
compile pkg ifaces modul =
  do  canonical   <- canonicalize pkg ifaces modul
      annotations <- typeCheck ifaces modul canonical
      ()          <- nitpick canonical
      objects     <- optimize modul annotations canonical
      return (Artifacts canonical annotations objects)



-- Ficcus: the same phases with the type recorder switched on. The extra
-- result holds the type of every expression and pattern node.
compileTyped :: Pkg.Name -> Map.Map Module.Name I.Interface -> Src.Module -> Either E.Error (Artifacts, Readout.Typed)
compileTyped pkg ifaces modul =
  do  canonical   <- canonicalize pkg ifaces modul
      (annotations, typed) <- typeCheckTyped ifaces modul canonical
      ()          <- nitpick canonical
      objects     <- optimize modul annotations canonical
      return (Artifacts canonical annotations objects, typed)



-- PHASES


canonicalize :: Pkg.Name -> Map.Map Module.Name I.Interface -> Src.Module -> Either E.Error Can.Module
canonicalize pkg ifaces modul =
  case snd $ R.run $ Canonicalize.canonicalize pkg ifaces modul of
    Right canonical ->
      Right canonical

    Left errors ->
      Left $ E.BadNames errors


-- Ficcus (ATTACH A2): the solver gets the table of the members the module can see, and the annotation of a
-- constrained definition becomes its constrained scheme (Type.Members, AST.Constraints)
typeCheck :: Map.Map Module.Name I.Interface -> Src.Module -> Can.Module -> Either E.Error (Map.Map N.Name Can.Annotation)
typeCheck ifaces modul canonical =
  case unsafePerformIO (Type.runWith (Members.toTable ifaces canonical) =<< Type.constrain Nothing canonical) of
    Right annotations ->
      Right (Map.union (Members.wrapAnnotations canonical annotations) (Members.embedded ifaces))

    Left errors ->
      Left (E.BadTypes (Localizer.fromModule modul) errors)


typeCheckTyped :: Map.Map Module.Name I.Interface -> Src.Module -> Can.Module -> Either E.Error (Map.Map N.Name Can.Annotation, Readout.Typed)
typeCheckTyped ifaces modul canonical =
  case unsafePerformIO (typeCheckTypedIO ifaces canonical) of
    Right result ->
      Right result

    Left errors ->
      Left (E.BadTypes (Localizer.fromModule modul) errors)


typeCheckTypedIO :: Map.Map Module.Name I.Interface -> Can.Module -> IO (Either (NE.List Error.Error) (Map.Map N.Name Can.Annotation, Readout.Typed))
typeCheckTypedIO ifaces canonical =
  do  recorder <- Recorder.new
      constraint <- Type.constrain (Just recorder) canonical
      result <- Type.runWith (Members.toTable ifaces canonical) constraint
      case result of
        Left errors ->
          return (Left errors)

        Right annotations ->
          do  typed <- Readout.readout recorder
              return (Right (Map.union (Members.wrapAnnotations canonical annotations) (Members.embedded ifaces), typed))


nitpick :: Can.Module -> Either E.Error ()
nitpick canonical =
  case PatternMatches.check canonical of
    Right () ->
      Right ()

    Left errors ->
      Left (E.BadPatterns errors)


optimize :: Src.Module -> Map.Map N.Name Can.Annotation -> Can.Module -> Either E.Error Opt.LocalGraph
optimize modul annotations canonical =
  case snd $ R.run $ Optimize.optimize annotations canonical of
    Right localGraph ->
      Right localGraph

    Left errors ->
      Left (E.BadMains (Localizer.fromModule modul) errors)
