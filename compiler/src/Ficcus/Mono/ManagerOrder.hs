{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE QuasiQuotes #-}
module Ficcus.Mono.ManagerOrder
  ( Entry(..)
  , managerOrder
  )
  where


-- Ficcus, effects slice E2 (E1 open point (b)): the order of the effect managers and ports.
--
-- Elm's run time keeps them in the JavaScript object `_Platform_effectManagers`, filled in the order in which the JS generator
-- emits their statements, and `_Platform_setupEffects` and `_Platform_dispatchEffects` iterate it in that order (`for (var key in
-- ...)`: insertion order for string keys). The order is observable: after an `update` every manager gets its `fx` message in this
-- order, so the `update`s that synchronous commands of two managers cause come in this order. E1 used the order of the manager
-- homes' names, which is not Elm's (the walk below puts Task before Random in a program whose own definition reaches Random
-- first; docs/EFFECTS-DESIGN.md D-fx-9).
--
-- The generator's walk (Generate.JavaScript.addGlobal) is a depth first, post order traversal from `main` over the dependency
-- sets of the optimized graph (Set order of Opt.Global: name, then home), where a manager's dependencies are its init, onEffects,
-- onSelfMsg, cmdMap, subMap in that order and a debugger kernel is skipped outside debug mode. This module repeats the walk and
-- records the Manager and Port nodes at the point their statement would be emitted. It never builds JavaScript.


import qualified Data.Map as Map
import qualified Data.Set as Set

import qualified AST.Optimized as Opt
import qualified AST.Prim.Module as Module
import qualified AST.Prim.Name as N
import qualified Elm.ModuleName as ModuleName
import qualified Elm.Package as Pkg


-- | a manager by its home (`elm/core:Task`), a port by its name
data Entry = EManager String | EPortOut String | EPortIn String
  deriving (Eq, Show)


managerOrder :: Opt.GlobalGraph -> [ModuleName.Canonical] -> [Entry]
managerOrder (Opt.GlobalGraph graph _) mains =
  reverse (snd (foldr (\home st -> visit st (Opt.Global home N.main)) (Set.empty, []) mains))
  where
    visit st@(seen, out) global
      | Set.member global seen = st
      | otherwise = help (Set.insert global seen, out) global

    deps st set = Set.foldl' visit st set

    help st global@(Opt.Global home name) =
      case Map.lookup global graph of
        Nothing -> st
        Just node ->
          case node of
            Opt.Define _ ds -> deps st ds
            Opt.DefineTailFunc _ _ ds -> deps st ds
            Opt.Ctor _ _ -> st
            Opt.Link linked -> visit st linked
            Opt.Cycle _ _ _ ds -> deps st ds
            Opt.Manager effectsType ->
              let dep n = Opt.Global home n
                  core = [ [N.ascii|init|], [N.ascii|onEffects|], [N.ascii|onSelfMsg|] ]
                  names = case effectsType of
                            Opt.Cmd -> core ++ [ [N.ascii|cmdMap|] ]
                            Opt.Sub -> core ++ [ [N.ascii|subMap|] ]
                            Opt.Fx -> core ++ [ [N.ascii|cmdMap|], [N.ascii|subMap|] ]
                  (seen', out') = foldl visit st (map dep names)
              in (seen', EManager (homeChars home) : out')
            Opt.Kernel _ ds -> if isDebugger home then st else deps st ds
            Opt.Enum _ -> st
            Opt.Box -> visit st (Opt.Global ModuleName.basics N.identity)
            Opt.PortIncoming _ ds -> let (s', o') = deps st ds in (s', EPortIn (N.toChars name) : o')
            Opt.PortOutgoing _ ds -> let (s', o') = deps st ds in (s', EPortOut (N.toChars name) : o')

    isDebugger (ModuleName.Canonical _ h) = Module.toString h == Module.kernelToString Module.kernel_debugger
    homeChars (ModuleName.Canonical pkg h) = Pkg.toChars pkg ++ ":" ++ Module.toChars h
