{-# LANGUAGE BangPatterns, TemplateHaskell #-}
module Generate
  ( debug
  , dev
  , prod
  , c
  , managerOrder
  , typeDumps
  , repl
  )
  where


import Prelude hiding (cycle, print)
import Control.Concurrent (readMVar)
import Control.Monad (liftM2)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Map.Utils as Map
import qualified Data.Maybe as Maybe
import qualified Data.NonEmptyList as NE
import qualified System.Directory as Dir
import qualified System.FilePath as FP

import qualified ThreadSafe.Fork as Fork

import qualified AST.Derive as Derive
import qualified AST.Members as Members
import qualified AST.Optimized as Opt
import qualified AST.Prim.Module as Module
import qualified AST.Prim.Name as N
import qualified Ficus.Mono.Overlay as Overlay
import qualified Ficus.Mono.ManagerOrder as ManagerOrder
import qualified Build
import qualified Elm.Compiler.Type.Extract as Extract
import qualified Elm.Details as Details
import qualified Elm.Interface as I
import qualified Elm.ModuleName as ModuleName
import qualified Elm.Package as Pkg
import qualified File
import qualified Generate.C as GC
import qualified Generate.JavaScript as JS
import qualified Generate.Mode as Mode
import qualified AST.Constraints as Constraints
import qualified AST.Selectors as Selectors
import qualified Nitpick.Constraints as NitpickConstraints
import qualified Nitpick.Debug as Nitpick
import qualified Reporting.Exit as Exit
import qualified Reporting.Task as Task
import qualified Root as R


-- NOTE: This is used by Make, Repl, and Reactor right now. But it may be
-- desireable to have Repl and Reactor to keep foreign objects in memory
-- to make things a bit faster?



-- GENERATORS


type Task a =
  Task.Task Exit.Generate a


debug :: R.Stuff -> Details.Details -> Build.Artifacts -> Task B.Builder
debug stuff details (Build.Artifacts pkg ifaces roots modules) =
  do  loading <- loadObjects stuff details modules
      types   <- loadTypes stuff ifaces modules
      objects <- finalizeObjects loading
      checkForConstraints objects
      let mode = Mode.Dev (Just types)
      let graph = objectsToGlobalGraph objects
      let mains = gatherMains pkg objects roots
      return $ JS.generate mode graph mains


dev :: R.Stuff -> Details.Details -> Build.Artifacts -> Task B.Builder
dev stuff details (Build.Artifacts pkg _ roots modules) =
  do  objects <- finalizeObjects =<< loadObjects stuff details modules
      checkForConstraints objects
      let mode = Mode.Dev Nothing
      let graph = objectsToGlobalGraph objects
      let mains = gatherMains pkg objects roots
      return $ JS.generate mode graph mains


prod :: R.Stuff -> Details.Details -> Build.Artifacts -> Task B.Builder
prod stuff details (Build.Artifacts pkg _ roots modules) =
  do  objects <- finalizeObjects =<< loadObjects stuff details modules
      checkForDebugUses objects
      checkForConstraints objects
      let graph = objectsToGlobalGraph objects
      let mode = Mode.Prod (Mode.shortenFieldNames graph)
      let mains = gatherMains pkg objects roots
      return $ JS.generate mode graph mains


-- Ficus: `--output=x.types`: the type dumps that Build wrote for the project modules
typeDumps :: R.Stuff -> Build.Artifacts -> IO B.Builder
typeDumps stuff (Build.Artifacts _ _ _ modules) =
  do  let names = List.sort (filter (\n -> Module.toChars n `notElem` Overlay.supportModuleNames) (map moduleName modules))
      dumps <- traverse (\n -> (,) n <$> readDump stuff n) names
      -- H21: the sorts of the overlay import the overlay's `Vector`, so it is part of every build to C; it is listed only when a module of
      -- the project uses it (a `Vector` of the project itself has no `ficVectorOverlay`)
      let overlayVector (n, bs) = Module.toChars n == "Vector" && BC.pack "id: author/project:Vector.ficVectorOverlay" `BS.isInfixOf` bs
          others = [ bs | (n, bs) <- dumps, Module.toChars n /= "Vector" ]
          unused (n, bs) = overlayVector (n, bs) && not (any (BC.pack "author/project:Vector." `BS.isInfixOf`) others)
          parts = [ B.byteString bs <> B.char7 '\n' | d@(_, bs) <- dumps, not (unused d) ]
      packages <- packageDumps stuff
      return (mconcat parts <> packages)


-- the dumps of the package modules (typed mode recompiled them from source)
packageDumps :: R.Stuff -> IO B.Builder
packageDumps stuff =
  do  let root = R.packageTypesDir stuff
      found <- Dir.doesDirectoryExist root
      if not found
        then return mempty
        else
          do  files <- listDumps root
              parts <- traverse (readPackageDump root) files
              return (mconcat parts)


listDumps :: FilePath -> IO [FilePath]
listDumps dir =
  do  entries <- List.sort <$> Dir.listDirectory dir
      concat <$> traverse (listEntry dir) entries


listEntry :: FilePath -> FilePath -> IO [FilePath]
listEntry dir entry =
  do  let path = dir FP.</> entry
      isDir <- Dir.doesDirectoryExist path
      if isDir
        then listDumps path
        else return [ path | FP.takeExtension path == ".types" ]


readPackageDump :: FilePath -> FilePath -> IO B.Builder
readPackageDump root path =
  do  bytes <- File.readUtf8 path
      let package = List.intercalate "/" (take 2 (FP.splitDirectories (FP.makeRelative root path)))
      return (B.string7 ("-- package " ++ package ++ "\n") <> B.byteString bytes <> B.char7 '\n')


moduleName :: Build.Module -> Module.Name
moduleName modul =
  case modul of
    Build.Fresh name _ _ -> name
    Build.Cached name _ _ -> name


readDump :: R.Stuff -> Module.Name -> IO BS.ByteString
readDump stuff name =
  do  let path = R.typesFile stuff name
      found <- File.exists path
      if found
        then File.readUtf8 path
        else return (BC.pack ("-- module " ++ Module.toChars name ++ ": no type dump (module was cached)"))


-- Ficus: C back end (milestone 1: a dump of the reachable optimized graph)
c :: R.Stuff -> Details.Details -> Build.Artifacts -> Task B.Builder
c stuff details (Build.Artifacts pkg _ roots modules) =
  do  objects <- finalizeObjects =<< loadObjects stuff details modules
      let graph = objectsToGlobalGraph objects
      let mains = gatherMains pkg objects roots
      return $ GC.dump graph mains


-- Ficus effects E2: the order of the effect managers and ports, as the JS generator emits them (Ficus.Mono.ManagerOrder)
managerOrder :: R.Stuff -> Details.Details -> Build.Artifacts -> Task [ManagerOrder.Entry]
managerOrder stuff details (Build.Artifacts pkg _ roots modules) =
  do  objects <- finalizeObjects =<< loadObjects stuff details modules
      let graph = objectsToGlobalGraph objects
      let mains = gatherMains pkg objects roots
      return $ ManagerOrder.managerOrder graph (Map.keys mains)


repl :: R.Stuff -> Details.Details -> Bool -> Build.ReplArtifacts -> N.Name -> Task B.Builder
repl stuff details ansi (Build.ReplArtifacts home modules localizer annotations) name =
  do  objects <- finalizeObjects =<< loadObjects stuff details modules
      let graph = objectsToGlobalGraph objects
      return $ JS.generateForRepl ansi localizer graph home name $
        $(Map.require 'repl) name annotations N.toChars



-- CHECK FOR DEBUG


checkForDebugUses :: Objects -> Task ()
checkForDebugUses (Objects _ locals) =
  case Map.keys (Map.filter Nitpick.hasDebugUses locals) of
    []   -> return ()
    m:ms -> Task.throw (Exit.GenerateCannotOptimizeDebugValues m ms)



-- Ficus (ATTACH A2): a constrained function (AST.Constraints) cannot be called from JavaScript yet
checkForConstraints :: Objects -> Task ()
checkForConstraints (Objects (Opt.GlobalGraph foreignNodes _) locals) =
  case concatMap NitpickConstraints.constrainedNodes (foreignNodes : map (\(Opt.LocalGraph _ nodes _) -> nodes) (Map.elems locals)) of
    [] -> return ()
    globals ->
      -- Ficus (A4a): a type with a `derive` line has its own report
      case [ Module.toChars home ++ "." ++ tipe ++ " derives " ++ members | Opt.Global (ModuleName.Canonical _ home) name <- globals, Just (tipe, members) <- [Derive.markerText name] ] of
        [] -> Task.throw (Exit.GenerateConstrainedFunctions (List.sort (map toChars globals)))
        derived -> Task.throw (Exit.GenerateDerivedMembers (List.sort derived))
  where
    globalHome (Opt.Global h _) = h
    toChars global@(Opt.Global (ModuleName.Canonical _ home) name)
      -- Ficus (A5b): a selector
      | Selectors.isAttachedHome (globalHome global) = "the attached function `" ++ N.toChars name ++ "` by its bare name"
      | name == Constraints.customOperators = Module.toChars home ++ ": operators on custom types (`+`, `<`, `==`, ...)"
      -- Ficus (A5a, D6): an inferred `where`
      | Constraints.splitInferredMarker name /= Nothing =
          let def = maybe name id (Constraints.splitInferredMarker name) in
          Module.toChars home ++ "." ++ Members.displayName def ++ " (no type annotation: "
            ++ (case Constraints.inferredSuggestion name of
                  -- (A5c, review B3) the type the solver would default it to
                  Just text -> "give it one such as `" ++ Members.displayName def ++ " : " ++ text ++ "`"
                  Nothing -> "give it one that names the types it is used at")
            ++ " to compile it to JavaScript)"
      | otherwise = Module.toChars home ++ "." ++ Members.displayName name



-- GATHER MAINS


gatherMains :: Pkg.Name -> Objects -> NE.List Build.Root -> Map.Map ModuleName.Canonical Opt.Main
gatherMains pkg (Objects _ locals) roots =
  Map.fromList $ Maybe.mapMaybe (lookupMain pkg locals) (NE.toList roots)


lookupMain :: Pkg.Name -> Map.Map Module.Name Opt.LocalGraph -> Build.Root -> Maybe (ModuleName.Canonical, Opt.Main)
lookupMain pkg locals root =
  let
    toPair name (Opt.LocalGraph maybeMain _ _) =
      (,) (ModuleName.Canonical pkg name) <$> maybeMain
  in
  case root of
    Build.Inside  name     -> toPair name =<< Map.lookup name locals
    Build.Outside name _ g -> toPair name g



-- LOADING OBJECTS


data LoadingObjects =
  LoadingObjects
    { _foreign_mvar :: Fork.SafeMVar (Maybe Opt.GlobalGraph)
    , _local_mvars :: Map.Map Module.Name (Fork.SafeMVar (Maybe Opt.LocalGraph))
    }


loadObjects :: R.Stuff -> Details.Details -> [Build.Module] -> Task LoadingObjects
loadObjects stuff details modules =
  Task.io $
  do  mvar <- Details.loadObjects stuff details
      mvars <- traverse (loadObject stuff) modules
      return $ LoadingObjects mvar (Map.fromList mvars)


loadObject :: R.Stuff -> Build.Module -> IO (Module.Name, Fork.SafeMVar (Maybe Opt.LocalGraph))
loadObject stuff modul =
  case modul of
    Build.Fresh  name _ graph -> (,) name <$> Fork.cached (Just graph)
    Build.Cached name _ _     -> (,) name <$> Fork.fork name (File.readBytes Opt.dLocalGraph (R.elmo stuff name))



-- FINALIZE OBJECTS


data Objects =
  Objects
    { _foreign :: Opt.GlobalGraph
    , _locals :: Map.Map Module.Name Opt.LocalGraph
    }


finalizeObjects :: LoadingObjects -> Task Objects
finalizeObjects (LoadingObjects mvar mvars) =
  Task.eio id $
  do  result  <- Fork.await mvar
      results <- traverse Fork.await mvars
      case liftM2 Objects result (sequence results) of
        Just loaded -> return (Right loaded)
        Nothing     -> return (Left Exit.GenerateCannotLoadArtifacts)


objectsToGlobalGraph :: Objects -> Opt.GlobalGraph
objectsToGlobalGraph (Objects globals locals) =
  foldr Opt.addLocalGraph globals locals



-- LOAD TYPES


loadTypes :: R.Stuff -> Map.Map ModuleName.Canonical I.DependencyInterface -> [Build.Module] -> Task Extract.Types
loadTypes stuff ifaces modules =
  Task.eio id $
  do  mvars <- traverse (loadTypesHelp stuff) modules
      let !foreigns = Extract.mergeMany (Map.elems (Map.mapWithKey Extract.fromDependencyInterface ifaces))
      results <- traverse Fork.await mvars
      case sequence results of
        Just ts -> return (Right (Extract.merge foreigns (Extract.mergeMany ts)))
        Nothing -> return (Left Exit.GenerateCannotLoadArtifacts)


loadTypesHelp :: R.Stuff -> Build.Module -> IO (Fork.SafeMVar (Maybe Extract.Types))
loadTypesHelp stuff modul =
  case modul of
    Build.Fresh name iface _ ->
      Fork.cached $ Just $ Extract.fromInterface name iface

    Build.Cached name _ ciMVar ->
      do  cachedInterface <- readMVar ciMVar
          case cachedInterface of
            Build.Unneeded ->
              Fork.fork name $
                do  maybeIface <- File.readBytes I.dInterface (R.elmi stuff name)
                    return $ Extract.fromInterface name <$> maybeIface

            Build.Loaded iface ->
              Fork.cached $ Just (Extract.fromInterface name iface)

            Build.Corrupted ->
              Fork.cached Nothing
