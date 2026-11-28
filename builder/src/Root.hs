{-# LANGUAGE EmptyDataDecls #-}
module Root
  ( Root
  , pwd
  , findRoot
  --
  , Stuff
  , getStuff
  --
  , elm_json
  , src
  , readme
  , license
  --
  , details
  , interfaces
  , objects
  , elmi
  , elmo
  , typesFile
  , packageTypesFile
  , packageTypesDir
  --
  , Path(..)
  , toAbsolutePath
  , toRelativePath
  , toOriginalPath
  --
  , PROJECT
  , withRootLock
  , PACKAGES
  , withRegistryLock
  --
  , PackageCache
  , getPackageCache
  , registry
  , package
  , packageRoot
  --
  , getReplCache
  , getReplTmpRoot
  --
  , prepublishDir
  --
  , ElmHome(..)
  , getElmHome
  )
  where


import qualified System.Directory as Dir
import qualified System.Environment as Env
import qualified Data.IORef as IORef
import qualified System.IO as IO
import qualified System.IO.Unsafe as Unsafe
import qualified System.FileLock as Lock
import qualified System.FilePath as FP
import System.FilePath ((</>), (<.>))

import qualified File
import qualified Ficus.Flags as Flags

import qualified AST.Prim.Module as Module
import qualified Elm.Package as Pkg
import qualified Elm.Version as V



-- ROOT


newtype Root = Root FilePath


pwd :: IO Root
pwd =
  Root <$> Dir.getCurrentDirectory


findRoot :: IO (Maybe Root)
findRoot =
  do  dir <- Dir.getCurrentDirectory
      findRootHelp (FP.splitDirectories dir)


findRootHelp :: [String] -> IO (Maybe Root)
findRootHelp dirs =
  case dirs of
    [] ->
      return Nothing

    _:_ ->
      do  exists <- Dir.doesFileExist (FP.joinPath dirs </> "elm.json")
          if exists
            then return $ Just $ Root $ FP.joinPath dirs
            else findRootHelp (init dirs)



-- STUFF


newtype Stuff = Stuff FilePath


getStuff :: Root -> IO Stuff
getStuff (Root root) =
  do  suffix <- Flags.getStuffSuffix   -- Ficus (G43)
      let dir = root </> "elm-stuff" </> (V.toChars V.compiler ++ suffix)
      Dir.createDirectoryIfMissing True dir
      return (Stuff dir)



-- PATHS


elm_json :: Root -> FilePath
src      :: Root -> FilePath
readme   :: Root -> FilePath
license  :: Root -> FilePath

elm_json (Root root) = root </> "elm.json"
src      (Root root) = root </> "src"
readme   (Root root) = root </> "README.md"
license  (Root root) = root </> "LICENSE"


details    :: Stuff -> FilePath
interfaces :: Stuff -> FilePath
objects    :: Stuff -> FilePath

details    (Stuff stuff) = stuff </> "d.dat"
interfaces (Stuff stuff) = stuff </> "i.dat"
objects    (Stuff stuff) = stuff </> "o.dat"


elmi :: Stuff -> Module.Name -> FilePath
elmo :: Stuff -> Module.Name -> FilePath

elmi (Stuff stuff) name = stuff </> Module.toDashPath name <.> "elmi"
elmo (Stuff stuff) name = stuff </> Module.toDashPath name <.> "elmo"


-- Ficus: the type dump of one module (`--output=x.types`)
typesFile :: Stuff -> Module.Name -> FilePath
typesFile (Stuff stuff) name = stuff </> Module.toDashPath name <.> "types"


-- Ficus: the type dumps of package modules (typed mode recompiles packages)
packageTypesDir :: Stuff -> FilePath
packageTypesDir (Stuff stuff) = stuff </> "typed"


packageTypesFile :: Stuff -> Pkg.Name -> Module.Name -> FilePath
packageTypesFile stuff pkg name = packageTypesDir stuff </> Pkg.toUrl pkg </> Module.toDashPath name <.> "types"



-- PATH


data Path
  = Absolute FilePath
  | Relative FilePath
  deriving (Eq)


toAbsolutePath :: Root -> Path -> FilePath
toAbsolutePath (Root root) path =
  case path of
    Absolute dir -> dir
    Relative dir -> root </> dir


toRelativePath :: Root -> FilePath -> FilePath
toRelativePath (Root root) path =
  FP.makeRelative root path


toOriginalPath :: Path -> FilePath
toOriginalPath path =
  case path of
    Absolute dir -> dir
    Relative dir -> dir



-- LOCK


data PROJECT


withRootLock :: Root -> (File.Writer t -> Stuff -> IO a) -> IO a
withRootLock root callback =
  File.withWriter $ \writer ->
    do  stuff@(Stuff dir) <- getStuff root
        Lock.withFileLock (dir </> "lock") Lock.Exclusive (\_ -> callback writer stuff)



-- REGISTRY LOCK
--
-- PERF since many artifacts are guaranteed to be the same every time, maybe try
-- to find a way to write temporary files and then move them into place. If two
-- processes overwrite each other that should be okay.


data PACKAGES


withRegistryLock :: PackageCache -> (File.Writer PACKAGES -> IO a) -> IO a
withRegistryLock (PackageCache dir) callback =
  File.withWriter $ \writer ->
    Lock.withFileLock (dir </> "lock") Lock.Exclusive (\_ -> callback writer)



-- PACKAGE CACHES


newtype PackageCache = PackageCache FilePath


getPackageCache :: IO PackageCache
getPackageCache =
  PackageCache <$> getCacheDir "packages"


registry :: PackageCache -> FilePath
registry (PackageCache dir) =
  dir </> "registry.dat"


package :: PackageCache -> Pkg.Name -> V.Version -> FilePath
package (PackageCache dir) name version =
  dir </> Pkg.toFilePath name </> V.toChars version


packageRoot :: PackageCache -> Pkg.Name -> V.Version -> Root
packageRoot c p v =
  Root (package c p v)



-- CACHE


getReplCache :: IO FilePath
getReplCache =
  getCacheDir "repl"


getReplTmpRoot :: IO Root
getReplTmpRoot =
  do  dir <- getCacheDir "repl"
      return $ Root (dir </> "tmp")


getCacheDir :: FilePath -> IO FilePath
getCacheDir projectName =
  do  (ElmHome home) <- getElmHome
      let root = home </> V.toChars V.compiler </> projectName
      Dir.createDirectoryIfMissing True root
      return root



-- PUBLISH


prepublishDir :: Root -> (Root, FilePath)
prepublishDir (Root root) =
    (Root dir, dir)
  where
    dir = root </> "prepublish"



-- ELM HOME


newtype ElmHome =
  ElmHome FilePath


getElmHome :: IO ElmHome
getElmHome =
  do  ficusHome <- Env.lookupEnv "FICUS_HOME"
      elmHome <- Env.lookupEnv "ELM_HOME"
      case (ficusHome, elmHome) of
        (Just customHome, _) -> return $ ElmHome customHome
        (Nothing, Just customHome) ->
          do  warnElmHome
              return $ ElmHome customHome
        (Nothing, Nothing) -> ElmHome <$> Dir.getAppUserDataDirectory "elm"


-- R1: ELM_HOME is the deprecated fallback of FICUS_HOME. The warning goes to an interactive stderr only, once per
-- process, so that captured output (the tests, differential runs against Elm) stays byte for byte as before.
warnElmHome :: IO ()
warnElmHome =
  do  first <- IORef.atomicModifyIORef' elmHomeWarned (\w -> (True, not w))
      tty <- IO.hIsTerminalDevice IO.stderr
      if first && tty
        then IO.hPutStrLn IO.stderr "warning: ELM_HOME is deprecated, set FICUS_HOME instead (ELM_HOME is used because FICUS_HOME is not set)"
        else return ()


{-# NOINLINE elmHomeWarned #-}
elmHomeWarned :: IORef.IORef Bool
elmHomeWarned =
  Unsafe.unsafePerformIO (IORef.newIORef False)

