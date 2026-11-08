{-# OPTIONS_GHC -Wall #-}
module Ficcus.Mono.Modules
  ( ModuleData(..)
  , fromCanonical
  , register
  , takeAll
  )
  where


-- Ficcus, stage (iii) slice 1: the canonical modules of the program with their recorded types, kept in
-- memory for the specializer (docs/STAGE3-PLAN.md section 1: the specializer runs on `Can` plus the
-- recorded table). Only filled when the output is `.c` (Ficcus.Flags.getKeepModules): a big project keeps
-- every module of every package alive until the specializer has run.


import Data.IORef (IORef, atomicModifyIORef', newIORef)
import qualified Data.List as List
import System.IO.Unsafe (unsafePerformIO)

import qualified AST.Canonical as Can
import qualified AST.Prim.TypeName as T
import qualified AST.Prim.Name as N
import qualified Data.Map.Strict as Map
import Type.Dump (Ctx, mkCtx, declsToDefs, moduleLabel, moduleChars)
import Type.Readout (Typed)


data ModuleData =
  ModuleData
    { mmName :: String                 -- e.g. `author/project:Fibonacci`
    , mmProject :: Bool
    , mmCtx :: Ctx
    , mmDefs :: [Can.Def]              -- top level definitions, dependencies first (Elm's order)
    , mmEnums :: [(String, Bool)]      -- custom types of the module (`Module.Type`), True when every constructor is nullary
    }


fromCanonical :: Bool -> Can.Module -> Typed -> ModuleData
fromCanonical isProject canonical@(Can.Module home _ _ decls unions _ _ _) typed =
  ModuleData
    { mmName = moduleLabel canonical
    , mmProject = isProject
    , mmCtx = mkCtx home decls typed
    , mmDefs = declsToDefs decls
    , mmEnums = [ (moduleChars home ++ "." ++ N.toChars (T.nameToName tname), isEnum opts) | (tname, Can.Union _ _ _ opts) <- Map.toList unions ]
    }
  where
    isEnum opts = case opts of { Can.Enum -> True; _ -> False }


{-# NOINLINE registry #-}
registry :: IORef [ModuleData]
registry =
  unsafePerformIO (newIORef [])


register :: ModuleData -> IO ()
register m =
  atomicModifyIORef' registry (\old -> (m : old, ()))


takeAll :: IO [ModuleData]
takeAll =
  do  all' <- atomicModifyIORef' registry (\old -> ([], old))
      return (List.sortOn (\m -> (not (mmProject m), mmName m)) all')
