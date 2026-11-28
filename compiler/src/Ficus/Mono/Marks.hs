{-# OPTIONS_GHC -Wall #-}
module Ficus.Mono.Marks
  ( Mark(..)
  , Marks
  , compute
  , computeWith
  , marksOf
  , isKeyed
  )
  where


-- Ficus, stage (iii) slice 0: which quantified variables of a definition are keyed by their exact type.
--
-- A variable is marked when
--   * its kind is `number`, `comparable`, `appendable` or `compappend` (the scheme says so), or
--   * it is *Equatable*: the operand type of `==` / `/=` (the first variable of `elm/core:Basics.eq`
--     and `neq`), or a variable that occurs in the instance bound to a marked variable of a callee
--     (propagated to the owner of every variable in the instance type; a fixpoint), or
--   * it is *Printed*: the same, from the roots `Debug.toString` and `Debug.log` (only matters in builds
--     with Debug, STAGE3-DESIGN review addition 1).
--   * it is an *Element* (V1, docs/STAGE4-V1.md): the element type of a flat Vector, from the roots that are the intrinsics of the
--     overlay module `Vector` (overlay/Vector.elm). The elements are stored in the layout of their exact type, so every function
--     that reads, writes or creates elements needs it; a function that only passes a vector on does not.
-- `row` variables are listed by kind (keyed by layout, not by type).
-- The equatable fixpoint is the one of `ficus-tests/scheme_stats.py`, which counted it on 4.6 million
-- instances; `ficus-tests/marks_check.py` compares the two.


import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import qualified AST.Selectors as Selectors
import Ficus.Mono.Facts
import Ficus.Mono.Kernel (vectorKernels)
import Ficus.Mono.Overlay (vectorModuleId)


data Mark = Equatable | Printed | Element
  deriving (Eq, Ord, Show)


-- | marks reached by propagation, for (definition id, variable index)
type Marks = Map.Map (String, Int) (Set.Set Mark)


compute :: [ModuleFacts] -> Marks
compute =
  computeWith []


-- | with extra roots that are keyed by their exact type (Ficus.Mono.Members.exactRoots: the variables of the
-- constraints of constrained definitions); they propagate to the callers like the equatable ones
computeWith :: [(String, Int)] -> [ModuleFacts] -> Marks
computeWith exactRoots modules =
  Map.unionsWith Set.union [fixpoint Equatable (equatableRoots ++ exactRoots), fixpoint Printed printedRoots, fixpoint Element elementRoots]
  where
    uses = concatMap mfUses modules
    byCallee = Map.fromListWith (++) [ (ufCallee u, [u]) | u <- uses ]
    known = Set.fromList [ dfId d | m <- modules, d <- mfDefs m ]

    equatableRoots = [ ("elm/core:Basics.eq", 0), ("elm/core:Basics.neq", 0) ] ++ relaxedRoots ++ selectorRoots
    -- (A5b) a selector (a bare attached function name, AST.Selectors) calls the member of its subject's exact type: every
    -- variable of its type at a use is keyed by its exact type (the others are decided by the subject anyway)
    selectorRoots = List.nub [ (ufCallee u, i) | u <- uses, Selectors.isSelectorId (ufCallee u), (i, _) <- ufBinds u ]
    -- (A5a) a relaxed `/ // modBy remainderBy` at a variable of its owner (Type.Dump records it as the use of index 0): the
    -- member of the exact type is called
    relaxedRoots = [ ("elm/core:Basics." ++ n, 0) | n <- ["fdiv", "idiv", "modBy", "remainderBy"] ]
    printedRoots = [ ("elm/core:Debug.toString", 0), ("elm/core:Debug.log", 0) ]
    -- only for the overlay's module Vector (it has the marker definition), not for a module of that name of the project or of a package
    elementRoots = [ (vectorModuleId ++ n, 0) | Set.member (vectorModuleId ++ "ficVectorOverlay") known, (n, _, _) <- vectorKernels ]

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
