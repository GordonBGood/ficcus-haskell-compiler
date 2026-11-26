{-# OPTIONS_GHC -Wall #-}
-- Ficcus (ATTACH, stage A2): constrained functions in the object graph.
module Nitpick.Constraints
  ( constrainedNodes
  , markInferred
  , markSelectors
  )
  where


import qualified Data.Map as Map
import qualified Data.Set as Set

import qualified AST.Constraints as Constraints
import qualified AST.Derive as Derive
import qualified AST.Optimized as Opt
import qualified AST.Canonical as Can
import qualified AST.Selectors as Selectors
import qualified AST.Prim.Name as N
import qualified Elm.ModuleName as ModuleName



-- THE OBJECT GRAPH
--
-- The JavaScript generator cannot call a constrained function yet (the members would have to be passed
-- at run time); `Generate` refuses a program that has one.  In the object graph a constrained function is
-- a function whose body starts with the destructuring of a hidden parameter.


-- | the constrained functions among the nodes of an object graph
constrainedNodes :: Map.Map Opt.Global Opt.Node -> [Opt.Global]
constrainedNodes nodes =
  concatMap found (Map.toList nodes)
  where
    found (global@(Opt.Global home _), node) =
      case node of
        Opt.Define _ _ | isMarker global -> [global]
        Opt.Define (Opt.Function _ body) _ | hiddenFirst body -> [global]
        Opt.DefineTailFunc _ body _ | hiddenFirst body -> [global]
        Opt.Cycle _ _ defs _ -> concatMap (inCycle home) defs
        _ -> []

    inCycle home def =
      case def of
        Opt.Def name (Opt.Function _ body) | hiddenFirst body -> [Opt.Global home name]
        Opt.TailDef name _ body | hiddenFirst body -> [Opt.Global home name]
        _ -> []

    isMarker (Opt.Global h name) =
      Selectors.isAttachedHome h                                                   -- Ficcus (A5b): a selector
        || name == Constraints.customOperators || Derive.markerText name /= Nothing    -- Ficcus (A4a): a `derive` line
        || Constraints.splitInferredMarker name /= Nothing                         -- Ficcus (A5a, D6): an inferred `where`

    hiddenFirst body =
      case body of
        Opt.Destruct (Opt.Destructor name _) rest ->
          case Constraints.splitMarker name of
            Just _ -> True
            Nothing -> hiddenFirst rest
        _ -> False




-- | Ficcus (A5a, D6): a top level definition without a type annotation whose requirements were inferred (its scheme
-- is `Constraints.isInferred`) gets a marker node `name$inferred`, a dependency of its own node so that it is in the
-- graph of every program that uses it; the JavaScript output refuses the marker like a constrained function and
-- suggests a type annotation
markInferred :: ModuleName.Canonical -> Map.Map N.Name Can.Annotation -> Opt.LocalGraph -> Opt.LocalGraph
markInferred home annotations graph@(Opt.LocalGraph main nodes fields) =
  case [ name | (name, Can.Forall _ tipe) <- Map.toList annotations, Constraints.isInferred tipe ] of
    [] -> graph
    inferred ->
      Opt.LocalGraph main (foldr mark nodes inferred) fields
  where
    mark name acc =
      let
        global = Opt.Global home name
        marker = Opt.Global home (Constraints.inferredMarker name)
      in
      Map.insert marker (Opt.Define Opt.Unit Set.empty) (Map.adjust (addDep marker) global acc)

    addDep marker node =
      case node of
        Opt.Define e deps -> Opt.Define e (Set.insert marker deps)
        Opt.DefineTailFunc args e deps -> Opt.DefineTailFunc args e (Set.insert marker deps)
        Opt.Cycle names values defs deps -> Opt.Cycle names values defs (Set.insert marker deps)
        _ -> node



-- | Ficcus (A5b): a selector (a bare attached function name, AST.Selectors) is a use of `elm/core:$attached.m`, which no
-- module defines.  Each one a module uses gets a node of that name in the module's graph (no code, no dependencies), so
-- the graph is complete, and the JavaScript output refuses it like a constrained function.  A module without selectors
-- (every Elm module) keeps its graph.
markSelectors :: Opt.LocalGraph -> Opt.LocalGraph
markSelectors graph@(Opt.LocalGraph main nodes fields) =
  case Set.toList (Set.unions (map selectorsOf (Map.elems nodes))) of
    [] -> graph
    used -> Opt.LocalGraph main (foldr (\g -> Map.insert g (Opt.Define Opt.Unit Set.empty)) nodes used) fields
  where
    selectorsOf node =
      Set.filter (\(Opt.Global h _) -> Selectors.isAttachedHome h) $
        case node of
          Opt.Define _ deps -> deps
          Opt.DefineTailFunc _ _ deps -> deps
          Opt.Cycle _ _ _ deps -> deps
          Opt.PortIncoming _ deps -> deps
          Opt.PortOutgoing _ deps -> deps
          _ -> Set.empty
