{-# OPTIONS_GHC -Wall #-}
module Ficcus.Mono.Marks
  ( Mark(..)
  , Marks
  , compute
  , marksOf
  , isKeyed
  )
  where


-- Ficcus, stage (iii) slice 0: which quantified variables of a definition are keyed by their exact type.
--
-- A variable is marked when
--   * its kind is `number`, `comparable`, `appendable` or `compappend` (the scheme says so), or
--   * it is *Equatable*: the operand type of `==` / `/=` (the first variable of `elm/core:Basics.eq`
--     and `neq`), or a variable that occurs in the instance bound to a marked variable of a callee
--     (propagated to the owner of every variable in the instance type; a fixpoint), or
--   * it is *Printed*: the same, from the roots `Debug.toString` and `Debug.log` (only matters in builds
--     with Debug, STAGE3-DESIGN review addition 1).
-- `row` variables are listed by kind (keyed by layout, not by type).
-- The equatable fixpoint is the one of `ficcus-tests/scheme_stats.py`, which counted it on 4.6 million
-- instances; `ficcus-tests/marks_check.py` compares the two.


import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import Ficcus.Mono.Facts


data Mark = Equatable | Printed
  deriving (Eq, Ord, Show)


-- | marks reached by propagation, for (definition id, variable index)
type Marks = Map.Map (String, Int) (Set.Set Mark)


compute :: [ModuleFacts] -> Marks
compute modules =
  Map.unionWith Set.union (fixpoint Equatable equatableRoots) (fixpoint Printed printedRoots)
  where
    uses = concatMap mfUses modules
    byCallee = Map.fromListWith (++) [ (ufCallee u, [u]) | u <- uses ]
    known = Set.fromList [ dfId d | m <- modules, d <- mfDefs m ]

    equatableRoots = [ ("elm/core:Basics.eq", 0), ("elm/core:Basics.neq", 0) ]
    printedRoots = [ ("elm/core:Debug.toString", 0), ("elm/core:Debug.log", 0) ]

    fixpoint mark roots =
      let reached = go (Set.fromList roots) roots
      in Map.fromList [ (k, Set.singleton mark) | k@(d, _) <- Set.toList reached, Set.member d known ]

    go seen [] = seen
    go seen ((callee, ix) : rest) =
      let found =
            [ owner
            | u <- Map.findWithDefault [] callee byCallee
            , (i, owners) <- ufBinds u
            , i == ix
            , owner <- owners
            ]
          new = Set.toList (Set.difference (Set.fromList found) seen)
      in go (foldr Set.insert seen new) (new ++ rest)


-- | marks of one variable of a definition: its kind and the propagated marks
marksOf :: Marks -> String -> Int -> Set.Set Mark
marksOf marks d i =
  Map.findWithDefault Set.empty (d, i) marks


-- | variables keyed by their exact type: constrained kinds and equatable / printed marks
isKeyed :: String -> Set.Set Mark -> Bool
isKeyed kind marks =
  kind `elem` ["number", "comparable", "appendable", "compappend"] || not (Set.null marks)
