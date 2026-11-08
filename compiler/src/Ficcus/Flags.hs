module Ficcus.Flags
  ( setTypedOutput
  , getTypedOutput
  , setKeepModules
  , getKeepModules
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
