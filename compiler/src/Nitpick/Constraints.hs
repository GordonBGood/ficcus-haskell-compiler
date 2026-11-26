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
import qualified AST.Prim.TypeName as T
import qualified AST.Prim.TypeVar as TV
import qualified AST.WellKnown as WK
import qualified Elm.ModuleName as ModuleName
import qualified Reporting.Doc as D
import qualified Reporting.Render.Type as RT
import qualified Reporting.Render.Type.Localizer as L



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
markInferred :: L.Localizer -> ModuleName.Canonical -> Map.Map N.Name Can.Annotation -> Opt.LocalGraph -> Opt.LocalGraph
markInferred localizer home annotations graph@(Opt.LocalGraph main nodes fields) =
  case [ name | (name, Can.Forall _ tipe) <- Map.toList annotations, Constraints.isInferred tipe ] of
    [] -> graph
    inferred ->
      Opt.LocalGraph main (foldr mark nodes inferred) fields
  where
    mark name acc =
      let
        global = Opt.Global home name
        marker = Opt.Global home (Constraints.inferredMarkerWith name (Map.lookup name annotations >>= suggestion localizer))
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



-- | (A5c, review B3) the type annotation the JavaScript refusal suggests for an inferred constrained definition: its type
-- with every requirement's subject defaulted as the solver defaults a top level value (D3: Float when `div` or `fromFloat`
-- is required, else Int, if that type has every required member).  Nothing when a subject cannot be defaulted: the
-- refusal then says it in words.
suggestion :: L.Localizer -> Can.Annotation -> Maybe String
suggestion localizer (Can.Forall _ tipe) =
  do  (real, required) <- Constraints.unwrap tipe
      subjects <- traverse subjectOf required
      let groups = Map.fromListWith (++) [ (v, [N.toChars m]) | (v, Constraints.Required m _ _) <- zip subjects required ]
      defaults <- traverse defaultOf groups
      return (D.toLine (RT.canToDoc localizer RT.None (substitute defaults real)))
  where
    subjectOf (Constraints.Required _ subject _) =
      case subject of
        Can.TVar v -> Just (TV.varToChars v)
        _ -> Nothing

    defaultOf members =
      let order = if any (`elem` ["div", "fromFloat"]) members then [(WK.BFloat, T.float), (WK.BInt, T.int)] else [(WK.BInt, T.int), (WK.BFloat, T.float)] in
      case [ t | (k, t) <- order, all (WK.builtinHas k) members ] of
        t : _ -> Just (Can.TType ModuleName.basics t [])
        [] -> Nothing

    substitute defaults t =
      case t of
        Can.TVar v -> Map.findWithDefault t (TV.varToChars v) defaults
        Can.TLambda a b -> Can.TLambda (substitute defaults a) (substitute defaults b)
        Can.TType h n args -> Can.TType h n (map (substitute defaults) args)
        Can.TRecord fields ext -> Can.TRecord (Map.map (\(Can.FieldType i x) -> Can.FieldType i (substitute defaults x)) fields) ext
        Can.TUnit -> t
        Can.TPair a b -> Can.TPair (substitute defaults a) (substitute defaults b)
        Can.TTriple a b c -> Can.TTriple (substitute defaults a) (substitute defaults b) (substitute defaults c)
        Can.TAlias h n args real -> Can.TAlias h n [ (v, substitute defaults x) | (v, x) <- args ] real
