{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE PatternGuards #-}
module Ficus.Mono.Twin
  ( twinProgram
  , twinStats
  )
  where


-- Ficus, stage (iv) slice S7 part 3: closure objects give up their captured values (docs/STAGE4-S7.md, part 3).
--
-- The captured variables of a lifted function are borrowed in its body: the closure object holds the counts, a call of the closure
-- reads them, and the body dups what it stores or passes on. When the call is the last use of a closure that nobody else holds
-- (`fic_ap<n>_own`, count 1), the object dies right after the call and releases what the body has just dup'd.
--
-- This pass gives every lifted function clone that is used as a closure value and captures a reference a TWIN: the same body, but
-- the captured variables are OWNED (they are in the environment of the Rc pass like owned parameters, so the last use moves them and
-- a unique captured value stays unique). The C generator emits a second entry for the closure (`fic_code.own`) that takes the
-- captured values out of the object, frees the object (its shell only) and calls the twin; `fic_ap<n>_own` enters it when the
-- closure has count 1 and the call gives exactly its arity. A partial application of a known function is such a closure too
-- (the specializer makes a lifted clone for it), so it is covered by the same mechanism.
--
-- The twin is referred to by no expression: direct calls and closure values name the original. It runs only with `--rc`, after the
-- inliner and before the Rc pass. `FICUS_NO_CLO_STEAL=1` turns it off.


import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)

import Ficus.Mono.Class
import Ficus.Mono.Free
import Ficus.Mono.Ir
import Ficus.Mono.Layout (objSizeClass)
import Ficus.Mono.Reuse (placeToken)


{-# NOINLINE twinOn #-}
twinOn :: Bool
twinOn = unsafePerformIO (fmap (/= Just "1") (lookupEnv "FICUS_NO_CLO_STEAL"))


twinProgram :: MProgram -> MProgram
twinProgram program
  | not twinOn = program
  | otherwise =
      let clones = mpClones program
          caps = captures clones
          asValue = Set.fromList (concatMap (maybe [] valueRefs . mdBody) clones)
          hasBody d = case mdBody d of { Just _ -> True; Nothing -> False }
          wanted d =
            mdKind d == Function && mdLifted d /= Nothing && hasBody d && Just (mdClone d) /= mpMain program
              && Set.member (mdClone d) asValue && not (null (mdParams d)) && length (mdParams d) <= 9
              && any (refClass . snd) (Map.findWithDefault [] (mdClone d) caps)
          next = 1 + maximum (0 : [ n | d <- clones, let CloneId n = mdClone d ])
          picked = zip (filter wanted clones) [next ..]
          twinOf = Map.fromList [ (mdClone d, CloneId n) | (d, n) <- picked ]
          originals = [ d { mdTwin = Map.lookup (mdClone d) twinOf } | d <- clones ]
          twins = [ d { mdClone = CloneId n, mdTwin = Nothing, mdCapsOwned = True } | (d, n) <- picked ]
      in program { mpClones = originals ++ twins }


-- | the function clones an expression uses as values (not as the head of a call)
valueRefs :: MExpr -> [CloneId]
valueRefs e =
  case mNode e of
    MCall h args | MGlobal _ <- mNode h -> concatMap valueRefs args
    MGlobal c -> [c]
    _ -> concatMap valueRefs (children e)


-- | for the notes (measurement of item (a), reuse of the closure cell): the number of twins, and the number of twins whose body builds,
-- outside every call it makes, a constructor cell of the size class of its own closure object (the cell the second entry frees could
-- be handed to the twin as a reuse token there)
twinStats :: MProgram -> (Int, Int)
twinStats program =
  let clones = mpClones program
      caps = captures clones
      twins = [ d | d <- clones, mdCapsOwned d ]
      shell d = objSizeClass (CI64 : map snd (Map.findWithDefault [] (mdClone d) caps))       -- header, code pointer, captured values
      fits d = case (shell d, mdBody d) of
                 (Just k, Just body) -> case placeToken "t" k body of { Just _ -> True; Nothing -> False }
                 _ -> False
  in (length twins, length (filter fits twins))
