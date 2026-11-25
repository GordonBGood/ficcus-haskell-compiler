{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE PatternGuards #-}
module Ficcus.Mono.ManagerTable
  ( MgrEntry(..)
  , managerEntries
  , hasManagers
  , MapPairs(..)
  , mapPairs
  , pairIndex
  , mgrIndex
  )
  where


-- Ficcus, effects slice E2 (EFFECTS-CHECK section 5, step 4): the manager table of the C program, read from `main`'s worker call
-- (Ficcus.Mono.Spec.requestManager: `ficcus:manager@home hasCmd hasSub init onEffects onSelfMsg cmdMaps.. subMaps..`) and put
-- in Elm's order (Ficcus.Mono.ManagerOrder). The C generator emits one `fic_mgr_def` per entry and numbers the managers by their
-- position: a leaf (`command`/`subscription`) carries the number of its manager, a `Cmd.map`/`Sub.map` node the number of its
-- class pair, the index into every manager's cmdMap/subMap closures (the dispatch applies a map node's tagger with the manager's
-- map function at that pair, innermost tagger first, one map node at a time: Elm composes the taggers first and calls the map
-- function once, which is the same for every map function that keeps `map f << map g = map (f << g)`, as Task, Time and Random do).


import qualified Data.List as List
import qualified Data.Map.Strict as Map

import Ficcus.Mono.Class
import Ficcus.Mono.Effects (managerHome)
import Ficcus.Mono.Ir
import Ficcus.Mono.ManagerOrder (Entry(..))


data MgrEntry =
  MgrEntry
    { meHome :: String
    , meHasCmd :: Bool
    , meHasSub :: Bool
    , meInit :: MDef
    , meOnEffects :: MDef
    , meOnSelf :: MDef
    , meCmdMaps :: [MDef]          -- in the order of the program's Cmd.map pairs
    , meSubMaps :: [MDef]
    }


-- | the managers of the program in Elm's order (homes the walk did not see, which should not happen, come last by name)
managerEntries :: [Entry] -> Map.Map CloneId MDef -> CloneId -> [MgrEntry]
managerEntries order byId root =
  let found = case Map.lookup root byId >>= mdBody of
                Just (MExpr _ (MCall (MExpr _ (MKernel "elm/core:Platform.worker" _)) args)) ->
                  [ e | MExpr _ (MCall (MExpr _ (MKernel k _)) margs) <- args, Just h <- [managerHome k], Just e <- [entry h margs] ]
                _ -> []
      rank e = case List.elemIndex (EManager (meHome e)) order of { Just i -> (0 :: Int, i, meHome e); Nothing -> (1, 0, meHome e) }
  in List.sortOn rank found
  where
    entry h margs =
      case margs of
        MExpr _ (MLit (LInt c)) : MExpr _ (MLit (LInt s)) : rest ->
          let ds = [ d | MExpr _ (MGlobal g) <- rest, Just d <- [Map.lookup g byId] ]
          in case ds of
               i : e : o : maps ->
                 Just (MgrEntry h (c == 1) (s == 1) i e o [ d | d <- maps, ".cmdMap" `List.isSuffixOf` mdName d ]
                                                         [ d | d <- maps, ".subMap" `List.isSuffixOf` mdName d ])
               _ -> Nothing
        _ -> Nothing


hasManagers :: MProgram -> Bool
hasManagers program =
  case mpMain program of
    Nothing -> False
    Just root -> not (null (managerEntries [] (Map.fromList [ (mdClone d, d) | d <- mpClones program ]) root))


-- | the class pairs (a, b) of the cmdMap and subMap clones, in their order in the entries (Spec asks for the same pairs, in Set
-- order, of every manager)
data MapPairs = MapPairs { mpCmd :: [(Class, Class)], mpSub :: [(Class, Class)] }


mapPairs :: [MgrEntry] -> MapPairs
mapPairs es =
  MapPairs (pick meCmdMaps) (pick meSubMaps)
  where
    pick f = case [ map keyPair (f e) | e <- es, not (null (f e)) ] of { ps : _ -> ps; [] -> [] }
    keyPair d = case mdKey d of { Key [ByClass a, ByClass b] -> (a, b); _ -> (CRef, CRef) }


-- | the pair index of a `Cmd.map` (True) or `Sub.map` (False) node at the key of its kernel (`(a -> msg) -> Cmd a -> Cmd msg`);
-- 0 when no manager has a map function at the pair (then no leaf ever reaches it)
pairIndex :: MapPairs -> Bool -> Key -> Int
pairIndex ps isCmd key =
  case key of
    Key [ByClass a, ByClass b] | Just i <- List.elemIndex (boxedC a, boxedC b) (if isCmd then mpCmd ps else mpSub ps) -> i
    _ -> 0
  where
    boxedC c = case c of { CStruct _ -> CRef; _ -> c }


mgrIndex :: [MgrEntry] -> String -> Maybe Int
mgrIndex es home = List.findIndex ((== home) . meHome) es
