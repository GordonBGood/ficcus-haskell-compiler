{-# OPTIONS_GHC -Wall #-}
module Ficcus.Mono.Facts
  ( DefFact(..)
  , InitFact(..)
  , UseFact(..)
  , ModuleFacts(..)
  , register
  , takeAll
  )
  where


-- Ficcus, stage (iii) slice 0: what the specializer needs to know about a module, as data.
--
-- `Type.Dump` produces these while it walks a module with its recorded types; they are the same facts
-- that it prints in the `.types` dump (schemes with kinds, the owner variables in the substitution of a
-- use, the initialisation order). They are collected for the whole program in one process-wide registry,
-- because the marks (`Ficcus.Mono.Marks`) are a fixpoint over the call graph across modules.
-- Modules are compiled in parallel, so `register` is atomic and `takeAll` sorts.


import Data.IORef (IORef, atomicModifyIORef', newIORef)
import qualified Data.List as List
import System.IO.Unsafe (unsafePerformIO)


-- | a definition (top level, local or constructor) with the kind of each quantified variable v0, v1, ...
data DefFact =
  DefFact
    { dfId :: String
    , dfKinds :: [String]      -- any | number | comparable | appendable | compappend | row
    , dfCtor :: Bool
    }
  deriving (Eq, Show)


-- | the initialisation record of a top level definition (the `init:` line)
data InitFact =
  InitFact
    { ifId :: String
    , ifIndex :: Int
    , ifValue :: Bool          -- a definition without arguments
    , ifNeeds :: [String]      -- top level values of the module that must be initialised before it
    , ifDep :: Bool            -- value with a non-empty `needs`
    , ifGroup :: Maybe String  -- id of its recursive group, if it is in one
    }
  deriving (Eq, Show)


-- | a use of a definition: the owner variables (definition id, variable index) that occur in the type
-- bound to each quantified variable of the callee
data UseFact =
  UseFact
    { ufCallee :: String
    , ufBinds :: [(Int, [(String, Int)])]
    }
  deriving (Eq, Ord, Show)


data ModuleFacts =
  ModuleFacts
    { mfName :: String
    , mfProject :: Bool        -- a module of the project (not of a package)
    , mfDefs :: [DefFact]
    , mfInits :: [InitFact]
    , mfUses :: [UseFact]
    }
  deriving (Show)


{-# NOINLINE registry #-}
registry :: IORef [ModuleFacts]
registry =
  unsafePerformIO (newIORef [])


register :: ModuleFacts -> IO ()
register facts =
  atomicModifyIORef' registry (\old -> (facts : old, ()))


-- | all registered modules, project modules first, then by name; the registry is emptied
takeAll :: IO [ModuleFacts]
takeAll =
  do  all' <- atomicModifyIORef' registry (\old -> ([], old))
      return (List.sortOn (\m -> (not (mfProject m), mfName m)) all')
