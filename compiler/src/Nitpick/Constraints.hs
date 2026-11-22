{-# OPTIONS_GHC -Wall #-}
-- Ficcus (ATTACH, stage A2): constrained functions in the object graph.
module Nitpick.Constraints
  ( constrainedNodes
  )
  where


import qualified Data.Map as Map

import qualified AST.Constraints as Constraints
import qualified AST.Optimized as Opt



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

    isMarker (Opt.Global _ name) =
      name == Constraints.customOperators

    hiddenFirst body =
      case body of
        Opt.Destruct (Opt.Destructor name _) rest ->
          case Constraints.splitMarker name of
            Just _ -> True
            Nothing -> hiddenFirst rest
        _ -> False

