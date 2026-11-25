{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE PatternGuards #-}
module Ficcus.Mono.ManagerTable
  ( MgrEntry(..)
  , Slot(..)
  , slotName
  , managerSlots
  , hasManagers
  , MapPairs(..)
  , mapPairs
  , pairIndex
  , mapCloneAt
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
import qualified Data.Set as Set

import Ficcus.Mono.Effects (managerHome, mapKernelKind, portOf)
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


-- | a manager of the table: compiled from Elm, or a port (E2 step 7: outgoing?, name, payload type)
data Slot = SElm MgrEntry | SPort Bool String MType


slotName :: Slot -> String
slotName sl = case sl of { SElm e -> meHome e; SPort _ n _ -> n }


-- | the managers and ports of the program in Elm's order (those the walk did not see, which should not happen, come last by name)
managerSlots :: [Entry] -> Map.Map CloneId MDef -> CloneId -> [Slot]
managerSlots order byId root =
  let found = case Map.lookup root byId >>= mdBody of
                Just (MExpr _ (MCall (MExpr _ (MKernel "elm/core:Platform.worker" _)) args)) ->
                  [ SElm e | MExpr _ (MCall (MExpr _ (MKernel k _)) margs) <- args, Just h <- [managerHome k], Just e <- [entry h margs] ]
                _ -> []
      ports = Map.toList (Map.fromList [ ((n, isOut), m) | d <- Map.elems byId, Just b <- [mdBody d], (k, Key [ByType m]) <- kernels b, Just (isOut, n) <- [portOf k] ])
      entryOf sl = case sl of { SElm e -> EManager (meHome e); SPort True n _ -> EPortOut n; SPort False n _ -> EPortIn n }
      rank sl = case List.elemIndex (entryOf sl) order of { Just i -> (0 :: Int, i, slotName sl); Nothing -> (1, 0, slotName sl) }
  in List.sortOn rank (found ++ [ SPort isOut n m | ((n, isOut), m) <- ports ])
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


-- | the kernels a body calls or mentions, with their keys
kernels :: MExpr -> [(String, Key)]
kernels e = [ (k, key) | MKernel k key <- [mNode e] ] ++ concatMap kernels (children e)


hasManagers :: MProgram -> Bool
hasManagers program =
  case mpMain program of
    Nothing -> False
    Just root -> not (null (managerSlots [] (Map.fromList [ (mdClone d, d) | d <- mpClones program ]) root))


-- | the class pairs (a, b) of the program's `Cmd.map` and `Sub.map` nodes (sorted): a map node carries the index of its pair, and
-- every manager's table has its cmdMap/subMap clone at that pair in that place (Spec clones one per pair it saw)
data MapPairs = MapPairs { mpCmd :: [(Class, Class)], mpSub :: [(Class, Class)] }


mapPairs :: [MDef] -> MapPairs
mapPairs clones =
  MapPairs (pick True) (pick False)
  where
    found = Set.fromList [ (isCmd, boxedC a, boxedC b) | d <- clones, Just b0 <- [mdBody d], (k, Key [ByClass a, ByClass b]) <- kernels b0
                                                       , Just isCmd <- [mapKernelKind k] ]
    pick isCmd = [ (a, b) | (c, a, b) <- Set.toList found, c == isCmd ]


-- | the map clone of a manager at a pair (Nothing: the manager has none, so no node of the pair reaches its leaves)
mapCloneAt :: [MDef] -> (Class, Class) -> Maybe MDef
mapCloneAt ds pr = List.find (\d -> case mdKey d of { Key [ByClass a, ByClass b] -> (boxedC a, boxedC b) == pr; _ -> False }) ds


-- | the pair index of a `Cmd.map` (True) or `Sub.map` (False) node at the key of its kernel (`(a -> msg) -> Cmd a -> Cmd msg`);
-- 0 when no manager has a map function at the pair (then no leaf ever reaches it)
pairIndex :: MapPairs -> Bool -> Key -> Int
pairIndex ps isCmd key =
  case key of
    Key [ByClass a, ByClass b] | Just i <- List.elemIndex (boxedC a, boxedC b) (if isCmd then mpCmd ps else mpSub ps) -> i
    _ -> 0


boxedC :: Class -> Class
boxedC c = case c of { CStruct _ -> CRef; _ -> c }


mgrIndex :: [Slot] -> String -> Maybe Int
mgrIndex es home = List.findIndex ((== home) . slotName) es
