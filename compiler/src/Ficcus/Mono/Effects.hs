{-# OPTIONS_GHC -Wall #-}
module Ficcus.Mono.Effects
  ( noStepper
  , effectClassOf
  , kernelTypeIds
  , effectKernels
  , bagNoneKernel
  -- step 2: effect managers
  , Manager(..)
  , managerOf
  , leafKernelId
  , leafHome
  , managerKernelId
  , managerHome
  , mapKernelKind
  )
  where


-- Ficcus, effects slice E1 (docs/EFFECTS-CHECK.md section 5, step 1; docs/EFFECTS-DESIGN.md D-fx-2 amended).
--
-- The kernel types of the platform (`Cmd`, `Sub`, `Program`, `Task`, `ProcessId`, `Router`) are references: a Task node, a bag, a
-- process are counted heap objects with the header convention, and a value that crosses them uses the closure word ABI (a struct as
-- its FIC_TAG_BOX). Before E1 the first three were the unit class (commands were ignored, STAGE3-PLAN R9) and the last three, declared
-- `type X = X` in Platform.elm, fell to the enumeration class. `Cmd.none`/`Sub.none` are the static immortal empty bag
-- (runtime/fic_platform.h).
--
-- FICCUS_NO_STEPPER=1 (debug switch, like FICCUS_NO_KNOWN): the behaviour before E1 exactly: the old classes, `Cmd.none` = 0, and the
-- program is `init` only (no update, subscriptions or stepper; Ficcus.Mono.Program). For the identity checks against elmficW7a.


import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)

import qualified Data.List as List

import qualified AST.Canonical as Can
import qualified AST.Prim.TypeName as T
import qualified AST.Prim.Name as N
import Ficcus.Mono.Class (Class(..))


{-# NOINLINE noStepper #-}
noStepper :: Bool
noStepper = unsafePerformIO (fmap (== Just "1") (lookupEnv "FICCUS_NO_STEPPER"))


-- | the class of a platform kernel type by its id (`Module.Type`), Nothing for every other type
effectClassOf :: String -> Maybe Class
effectClassOf name
  | noStepper = if name `elem` ["elm/core:Platform.Cmd.Cmd", "elm/core:Platform.Sub.Sub", "elm/core:Platform.Program"] then Just CUnit else Nothing
  | name `elem` kernelTypeIds = Just CRef
  | otherwise = Nothing


-- | the kernel types of the platform: references to runtime objects (runtime/fic_sched.h), never unions of the program
kernelTypeIds :: [String]
kernelTypeIds =
  [ "elm/core:Platform.Cmd.Cmd", "elm/core:Platform.Sub.Sub", "elm/core:Platform.Program"
  , "elm/core:Platform.Task", "elm/core:Platform.ProcessId", "elm/core:Platform.Router" ]


-- | `Cmd.none` and `Sub.none`: kernel values (arity 0), the static empty bag
bagNoneKernel :: String -> Bool
bagNoneKernel n = n == "elm/core:Platform.Cmd.none" || n == "elm/core:Platform.Sub.none"


-- | the kernels of the scheduler and the platform (Elm's Scheduler.js and Platform.js): id, arity, ownership signature
-- (Ficcus.Mono.Kernel.kernelSig: `o` consumed or stored, `b` borrowed, `s` never a reference). A Task, bag or process STORES what it
-- is given, so every value and callback argument is `o`; a router and a process id are only looked at. The id is the Elm wrapper
-- (`Task.succeed = Elm.Kernel.Scheduler.succeed`), except `elm/core:Scheduler.spawn`, which `Task.spawnCmd` calls directly.
-- The C generator does not implement them before E2 (step 4, runtime/fic_sched.h): a program that reaches one is reported by name.
effectKernels :: [(String, Int, String)]
effectKernels =
  [ ("elm/core:Task.succeed", 1, "o"), ("elm/core:Task.fail", 1, "o")
  , ("elm/core:Task.andThen", 2, "oo"), ("elm/core:Task.onError", 2, "oo")
  , ("elm/core:Scheduler.spawn", 1, "o"), ("elm/core:Process.spawn", 1, "o")
  , ("elm/core:Process.sleep", 1, "s"), ("elm/core:Process.kill", 1, "b")
  , ("elm/core:Platform.sendToApp", 2, "bo"), ("elm/core:Platform.sendToSelf", 2, "bo")
  , ("elm/core:Platform.Cmd.batch", 1, "o"), ("elm/core:Platform.Cmd.map", 2, "oo")
  , ("elm/core:Platform.Sub.batch", 1, "o"), ("elm/core:Platform.Sub.map", 2, "oo")
    -- E2 step 5: elm/time's kernels (`Elm.Kernel.Time.now millisToPosix`, `setInterval`) and the two of overlay/FicOverlayTime.elm
  , ("elm/core:Time.now", 1, "o"), ("elm/time:Time.setInterval", 2, "so")
  , ("author/project:FicOverlayTime.hereOffset", 1, "s"), ("author/project:FicOverlayTime.zoneName", 1, "s")
  ]



-- STEP 2: EFFECT MANAGERS COMPILED FROM THEIR ELM SOURCE (EFFECTS-CHECK section 5, step 2)
--
-- An `effect module X where { command = MyCmd, subscription = MySub }` is a state machine whose five functions (`init`, `onEffects`,
-- `onSelfMsg`, `cmdMap`, `subMap`) are ordinary Elm definitions of the module. Elm's JS output registers them with
-- `_Platform_createManager` and makes `command`/`subscription` the leaf constructor `_Platform_leaf("X")` (Optimize.Module.addEffects,
-- Generate.JavaScript.generateManager). Here:
--
--   * `command`/`subscription` of a manager (a name with no definition: the canonicalizer adds it to the module's scope) is the
--     kernel `leafKernelId home` of arity 1, keyed by the class of its `msg` at the use (the value is stored: signature "o");
--   * when the program uses a leaf of a home, the specializer clones the manager's `init`, `onEffects` and `onSelfMsg` at the class of the
--     program's `msg` (after `gatherEffects` every command and subscription that reaches a manager is at the program's message type),
--     and its `cmdMap`/`subMap` at every class pair (a, b) of a `Cmd.map`/`Sub.map` of the program (the dispatch applies a map node's
--     tagger with the manager's own map function at that pair);
--   * the table is kept in `main`'s worker call (Ficcus.Mono.Spec), one `managerKernelId home` call per manager with the clones as
--     arguments: init, onEffects, onSelfMsg, then the cmdMap clones, then the subMap clones (each clone's key says its pair). `main`
--     is not counted or generated, and its references keep the clones alive through the later passes.
--
-- The scheduler kernels these clones call are E2 (step 4): until then the C generator reports them by name.


-- | an effect module: its home (`elm/core:Task`) and the names of its command and subscription types
data Manager =
  Manager
    { mgHome :: String
    , mgCmd :: Maybe String
    , mgSub :: Maybe String
    }
  deriving (Show)


managerOf :: String -> Can.Effects -> Maybe Manager
managerOf home effects =
  case effects of
    Can.Manager _ _ _ m ->
      Just $ case m of
        Can.Cmd c -> Manager home (Just (tname c)) Nothing
        Can.Sub sb -> Manager home Nothing (Just (tname sb))
        Can.Fx c sb -> Manager home (Just (tname c)) (Just (tname sb))
    _ -> Nothing
  where
    tname = N.toChars . T.nameToName


leafPrefix, managerPrefix :: String
leafPrefix = "elm/core:Platform.leaf@"
managerPrefix = "ficcus:manager@"


-- | the leaf constructor of a manager (`command`, `subscription`)
leafKernelId :: String -> String
leafKernelId home = leafPrefix ++ home


leafHome :: String -> Maybe String
leafHome = List.stripPrefix leafPrefix


-- | the entry of the manager table in `main` (never called; not in the kernel table)
managerKernelId :: String -> String
managerKernelId home = managerPrefix ++ home


managerHome :: String -> Maybe String
managerHome = List.stripPrefix managerPrefix


-- | `Cmd.map` (Just True) and `Sub.map` (Just False)
mapKernelKind :: String -> Maybe Bool
mapKernelKind n
  | n == "elm/core:Platform.Cmd.map" = Just True
  | n == "elm/core:Platform.Sub.map" = Just False
  | otherwise = Nothing
