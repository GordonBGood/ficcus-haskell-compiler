{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE PatternGuards #-}
module Ficcus.Mono.Program
  ( Shape(..)
  , programShape
  , modelSeeds
  )
  where


-- Ficcus, effects slice E1 step 3 (docs/EFFECTS-DESIGN.md D-fx-3 amended): the shape of the program as the specializer leaves it in
-- `main` (Ficcus.Mono.Spec.specWorker, workerPhase, managerPhase):
--
--   main = Platform.worker init update subscriptions (manager entries ...)
--
-- `main` itself is never counted, checked or generated; its call only names the clones. The typed stepper of the C generator calls
-- them directly, and the borrow inference makes the model parameter of `update` owned (the seed), so the stepper can MOVE the model
-- out of its slot into `update` and store the model `update` returns: the model is never copied by the protocol itself, only where a
-- second reference really exists (a capture in a command, a subscription, a tagger: the count is the truth).
-- With FICCUS_NO_STEPPER=1 (Ficcus.Mono.Effects) the call is `worker init` only, as before E1.


import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)

import Ficcus.Mono.Effects (managerHome)
import Ficcus.Mono.Free (refClass)
import Ficcus.Mono.Ir


data Shape =
  Shape
    { shInit :: MDef
    , shStep :: Maybe (MDef, MDef)        -- update and subscriptions (E1 step 3)
    , shManagers :: [String]              -- the homes of the effect managers (E1 step 2)
    }


programShape :: Maybe CloneId -> Map.Map CloneId MDef -> Maybe Shape
programShape root byId =
  do  r <- root
      d <- Map.lookup r byId
      MExpr _ (MCall (MExpr _ (MKernel "elm/core:Platform.worker" _)) args) <- mdBody d
      let globals = [ c | MExpr _ (MGlobal c) <- args ]
      initD <- case globals of { i : _ -> Map.lookup i byId; [] -> Nothing }
      let step = case globals of
                   [_, u, s] | Just ud <- Map.lookup u byId, Just sd <- Map.lookup s byId -> Just (ud, sd)
                   _ -> Nothing
      return (Shape initD step [ h | MExpr _ (MCall (MExpr _ (MKernel k _)) _) <- args, Just h <- [managerHome k] ])


{-# NOINLINE noModelSeed #-}
-- | FICCUS_NO_MODEL_SEED=1 (test switch, G17b): no seed, the model parameter gets what the ordinary rules give it
noModelSeed :: Bool
noModelSeed = unsafePerformIO (fmap (== Just "1") (lookupEnv "FICCUS_NO_MODEL_SEED"))


-- | the model parameter (the second) of `update`, when it is of a reference class: owned whatever the body does (Ficcus.Mono.Borrow)
modelSeeds :: Maybe CloneId -> [MDef] -> Set.Set (CloneId, String)
modelSeeds root clones =
  case (if noModelSeed then Nothing else programShape root (Map.fromList [ (mdClone d, d) | d <- clones ]) >>= shStep) of
    Just (ud, _) | mdKind ud == Function, [_, (m, c)] <- mdParams ud, refClass c -> Set.singleton (mdClone ud, m)
    _ -> Set.empty
