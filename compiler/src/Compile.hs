{-# OPTIONS_GHC -Wall -fno-warn-unused-do-bind #-}
module Compile
  ( Artifacts(..)
  , compile
  , compileTyped
  )
  where


import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.NonEmptyList as NE

import qualified AST.Source as Src
import qualified AST.Canonical as Can
import qualified AST.Constraints as Constraints
import qualified AST.Derive as Derive
import qualified AST.Members as AMembers
import qualified AST.Optimized as Opt
import qualified AST.Prim.Module as Module
import qualified AST.Prim.Name as N
import qualified Canonicalize.Module as Canonicalize
import qualified Elm.Interface as I
import qualified Elm.Package as Pkg
import qualified Nitpick.PatternMatches as PatternMatches
import qualified Optimize.Module as Optimize
import qualified Reporting.Error as E
import qualified String as S
import qualified Reporting.Error.Type as Error
import qualified Reporting.Result as R
import qualified Reporting.Render.Type.Localizer as Localizer
import qualified Type.Constrain.Module as Type
import qualified Type.Members as Members
import qualified Type.Requirements as Requirements
import qualified Nitpick.Constraints as NitpickConstraints
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
      annotations0 <- typeCheck ifaces modul canonical
      ()          <- nitpick canonical
      objects0    <- optimize modul annotations0 canonical
      let (annotations, objects) = markCustomOperators (Localizer.fromModule modul) canonical annotations0 objects0
      return (Artifacts canonical annotations objects)



-- Ficcus: the same phases with the type recorder switched on. The extra
-- result holds the type of every expression and pattern node.
compileTyped :: Pkg.Name -> Map.Map Module.Name I.Interface -> Src.Module -> Either E.Error (Artifacts, Readout.Typed)
compileTyped pkg ifaces modul =
  do  canonical   <- canonicalize pkg ifaces modul
      (annotations0, typed) <- typeCheckTyped ifaces modul canonical
      ()          <- nitpick canonical
      objects0    <- optimize modul annotations0 canonical
      let (annotations, objects) = markCustomOperators (Localizer.fromModule modul) canonical annotations0 objects0
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
  case unsafePerformIO (checkShapes canonical (Type.runWith (Members.toTable ifaces canonical) (Requirements.kindsOf canonical) =<< Type.constrain Nothing canonical)) of
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
      result <- checkShapes canonical (Type.runWith (Members.toTable ifaces canonical) (Requirements.kindsOf canonical) constraint)
      case result of
        Left errors ->
          return (Left errors)

        Right annotations ->
          do  typed <- Readout.readout recorder
              return (Right (Map.union (Members.wrapAnnotations canonical annotations) (Members.embedded ifaces), typed))


-- Ficcus (ATTACH A3): a module that uses operators at a custom type gets a marker node in its object graph (the
-- JavaScript output refuses it, Nitpick.Constraints); the annotation the solver made for the marker is dropped
markCustomOperators :: Localizer.Localizer -> Can.Module -> Map.Map N.Name Can.Annotation -> Opt.LocalGraph -> (Map.Map N.Name Can.Annotation, Opt.LocalGraph)
markCustomOperators localizer canonical@(Can.Module home _ _ _ _ _ _ _) annotations1 objects =
  markCustomOperators1 canonical (Map.filterWithKey (\name _ -> Derive.markerText name == Nothing) annotations1)
    (NitpickConstraints.markSelectors (NitpickConstraints.markInferred localizer home annotations1 objects))     -- Ficcus (A5a, D6; A5b; A5c B3)
  -- Ficcus (A4a): the markers of the `derive` lines (Canonicalize.Derive) stay in the object graph, not in the interface


markCustomOperators1 :: Can.Module -> Map.Map N.Name Can.Annotation -> Opt.LocalGraph -> (Map.Map N.Name Can.Annotation, Opt.LocalGraph)
markCustomOperators1 (Can.Module home _ _ decls _ _ _ _) annotations objects@(Opt.LocalGraph main nodes fields) =
  if Map.member Constraints.customOperators annotations || definesEq
    then
      ( Map.delete Constraints.customOperators annotations
      , Opt.LocalGraph main (Map.insert (Opt.Global home Constraints.customOperators) (Opt.Define Opt.Unit Set.empty) nodes) fields
      )
    else
      (annotations, objects)
  where
    -- `==` and `/=` stay structural in the JavaScript output, so a module that defines an `eq` member is refused
    -- there (used or not, like a constrained function)
    definesEq =
      any (\def -> fmap snd (AMembers.split (Members.nameOf def)) == Just eqName) (Members.defsOf decls)
    eqName = N.fromString (S.fromChars "eq")

-- Ficcus (ATTACH A3): a well known member with the wrong type is reported before anything else is checked
checkShapes :: Can.Module -> IO (Either (NE.List Error.Error) a) -> IO (Either (NE.List Error.Error) a)
checkShapes canonical check =
  case Members.shapeErrors canonical of
    e:es -> return (Left (NE.List e es))
    [] -> check


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
