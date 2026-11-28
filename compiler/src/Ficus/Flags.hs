module Ficus.Flags
  ( setTypedOutput
  , getTypedOutput
  , setKeepModules
  , getKeepModules
  , setExtraSrcDir
  , getExtraSrcDir
  , setOverlayOnlyPkgs
  , getOverlayOnlyPkgs
  , setCorePackages
  , getCorePackages
  , setStuffSuffix
  , getStuffSuffix
  , ficusChecks
  )
  where


-- Ficus: process wide switches set once, before any module is compiled.
--
-- The typed output (`--output=x.types`) needs every project module to be
-- compiled with the type recorder switched on. The flag is written once by
-- Make.run and only read afterwards, so it does not interfere with the
-- parallel compilation of modules.


import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import System.IO.Unsafe (unsafePerformIO)


{-# NOINLINE typedOutputRef #-}
typedOutputRef :: IORef Bool
typedOutputRef =
  unsafePerformIO (newIORef False)


setTypedOutput :: Bool -> IO ()
setTypedOutput =
  writeIORef typedOutputRef


getTypedOutput :: IO Bool
getTypedOutput =
  readIORef typedOutputRef


-- the canonical modules and their recorded types are kept for the specializer (`--output=x.c`)
{-# NOINLINE keepModulesRef #-}
keepModulesRef :: IORef Bool
keepModulesRef =
  unsafePerformIO (newIORef False)


setKeepModules :: Bool -> IO ()
setKeepModules =
  writeIORef keepModulesRef


getKeepModules :: IO Bool
getKeepModules =
  readIORef keepModulesRef


-- the directory of the overlay module (Ficus.Mono.Overlay), searched for modules after the project's source directories
{-# NOINLINE extraSrcDirRef #-}
extraSrcDirRef :: IORef (Maybe FilePath)
extraSrcDirRef =
  unsafePerformIO (newIORef Nothing)


setExtraSrcDir :: Maybe FilePath -> IO ()
setExtraSrcDir =
  writeIORef extraSrcDirRef


getExtraSrcDir :: IO (Maybe FilePath)
getExtraSrcDir =
  readIORef extraSrcDirRef


-- L42: the packages that an application lists as indirect and that an overlay module (Ficus.Mono.Overlay) imports. Elm.Details
-- makes their modules importable for a build to C; Build lets only the overlay modules import them, so that Elm's rule (a module of a
-- package that is not a direct dependency cannot be imported) still holds for the program. Written by Details.verifyApp.
{-# NOINLINE overlayOnlyPkgsRef #-}
overlayOnlyPkgsRef :: IORef [String]
overlayOnlyPkgsRef =
  unsafePerformIO (newIORef [])


setOverlayOnlyPkgs :: [String] -> IO ()
setOverlayOnlyPkgs =
  writeIORef overlayOnlyPkgsRef


getOverlayOnlyPkgs :: IO [String]
getOverlayOnlyPkgs =
  readIORef overlayOnlyPkgsRef


-- the checks that only the C back end makes (decisions L2 and L9: an Int literal beyond 2^63-1 and a surrogate in a string
-- literal are errors). Elm's JavaScript builds keep accepting them, so the corpus comparisons stay identical.
-- Read when the first module is canonicalized, after Make has set the flag.
{-# NOINLINE ficusChecks #-}
ficusChecks :: Bool
ficusChecks =
  unsafePerformIO (readIORef keepModulesRef)


-- G43: are the Ficus core packages substituted for the Elm packages of the same name in a build to C? On unless the project's
-- elm.json says `"ficus-core-packages": false` (Ficus.CorePackages). Written by Make.run.
{-# NOINLINE corePackagesRef #-}
corePackagesRef :: IORef Bool
corePackagesRef =
  unsafePerformIO (newIORef True)


setCorePackages :: Bool -> IO ()
setCorePackages =
  writeIORef corePackagesRef


getCorePackages :: IO Bool
getCorePackages =
  readIORef corePackagesRef


-- G43: a build to C that may use a core package keeps its caches in `elm-stuff/<version>-ficus-core`, so that a later build to
-- JavaScript in the same project never reads artifacts that contain the core package (Root.getStuff). Set by Make.run.
{-# NOINLINE stuffSuffixRef #-}
stuffSuffixRef :: IORef String
stuffSuffixRef =
  unsafePerformIO (newIORef "")


setStuffSuffix :: String -> IO ()
setStuffSuffix =
  writeIORef stuffSuffixRef


getStuffSuffix :: IO String
getStuffSuffix =
  readIORef stuffSuffixRef
