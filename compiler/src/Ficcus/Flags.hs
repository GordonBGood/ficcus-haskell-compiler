module Ficcus.Flags
  ( setTypedOutput
  , getTypedOutput
  , setKeepModules
  , getKeepModules
  , setExtraSrcDir
  , getExtraSrcDir
  , ficcusChecks
  )
  where


-- Ficcus: process wide switches set once, before any module is compiled.
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


-- the directory of the overlay module (Ficcus.Mono.Overlay), searched for modules after the project's source directories
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


-- the checks that only the C back end makes (decisions L2 and L9: an Int literal beyond 2^63-1 and a surrogate in a string
-- literal are errors). Elm's JavaScript builds keep accepting them, so the corpus comparisons stay identical.
-- Read when the first module is canonicalized, after Make has set the flag.
{-# NOINLINE ficcusChecks #-}
ficcusChecks :: Bool
ficcusChecks =
  unsafePerformIO (readIORef keepModulesRef)
