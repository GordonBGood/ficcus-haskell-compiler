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
import Ficcus.Mono.Class (MType(..))
import Ficcus.Mono.Ir (UnionShape(..))
import qualified AST.Prim.TypeVar as TV
import qualified Data.Index as Index
import Type.Dump (Ctx, mkCtx, declsToDefs, moduleLabel, moduleChars)
import Type.Readout (Typed)


data ModuleData =
  ModuleData
    { mmName :: String                 -- e.g. `author/project:Fibonacci`
    , mmProject :: Bool
    , mmCtx :: Ctx
    , mmDefs :: [Can.Def]              -- top level definitions, dependencies first (Elm's order)
    , mmEnums :: [(String, Bool)]      -- custom types of the module (`Module.Type`), True when every constructor is nullary
    , mmUnions :: [(String, UnionShape)]   -- the same types with their constructors (for generated equality and comparison)
    }


fromCanonical :: Bool -> Can.Module -> Typed -> ModuleData
fromCanonical isProject canonical@(Can.Module home _ _ decls unions _ _ _) typed =
  ModuleData
    { mmName = moduleLabel canonical
    , mmProject = isProject
    , mmCtx = mkCtx home decls typed
    , mmDefs = declsToDefs decls
    , mmEnums = [ (moduleChars home ++ "." ++ N.toChars (T.nameToName tname), isEnum opts) | (tname, Can.Union _ _ _ opts) <- Map.toList unions ]
    , mmUnions = [ (moduleChars home ++ "." ++ N.toChars (T.nameToName tname), shapeOf u) | (tname, u) <- Map.toList unions ]
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


shapeOf :: Can.Union -> UnionShape
shapeOf (Can.Union vars alts _ opts) =
  UnionShape
    { usEnum = case opts of { Can.Enum -> True; _ -> False }
    , usCtors = [ (N.toChars cname, Index.toMachine ix, map (canToM env) args) | Can.Ctor cname ix _ args <- alts ]
    }
  where
    env = Map.fromList [ (TV.varToChars v, TyCon ("#" ++ show i) []) | (i, v) <- zip [0 :: Int ..] vars ]


-- a canonical type of a constructor field as an MType; the variables are looked up in `env`
canToM :: Map.Map String MType -> Can.Type -> MType
canToM env t =
  case t of
    Can.TLambda a b -> TyFun (go a) (go b)
    Can.TVar v -> Map.findWithDefault (TyCon "ref" []) (TV.varToChars v) env
    Can.TType home name args -> TyCon (moduleChars home ++ "." ++ N.toChars (T.nameToName name)) (map go args)
    Can.TRecord fields _ -> TyRecord [ (N.toChars n, go ft) | (n, Can.FieldType _ ft) <- Map.toList fields ]
    Can.TUnit -> TyUnit
    Can.TPair a b -> TyTuple [go a, go b]
    Can.TTriple a b c -> TyTuple [go a, go b, go c]
    Can.TAlias _ _ args aliased ->
      case aliased of
        Can.Filled real -> go real
        Can.Holey real -> canToM (Map.union (Map.fromList [ (TV.varToChars v, go x) | (v, x) <- args ]) env) real
  where
    go = canToM env
