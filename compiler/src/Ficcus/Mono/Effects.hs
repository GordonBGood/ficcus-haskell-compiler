{-# OPTIONS_GHC -Wall #-}
module Ficcus.Mono.Effects
  ( noStepper
  , effectClassOf
  , effectKernels
  , bagNoneKernel
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

import Ficcus.Mono.Class (Class(..))


{-# NOINLINE noStepper #-}
noStepper :: Bool
noStepper = unsafePerformIO (fmap (== Just "1") (lookupEnv "FICCUS_NO_STEPPER"))


-- | the class of a platform kernel type by its id (`Module.Type`), Nothing for every other type
effectClassOf :: String -> Maybe Class
effectClassOf name
  | noStepper = if name `elem` ["elm/core:Platform.Cmd.Cmd", "elm/core:Platform.Sub.Sub", "elm/core:Platform.Program"] then Just CUnit else Nothing
  | name `elem` kernelTypes = Just CRef
  | otherwise = Nothing
  where
    kernelTypes =
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
  ]

