{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE PatternGuards #-}
module Ficcus.Mono.Unbox
  ( unboxProgram
  , UnboxResult(..)
  , unboxOn
  , workerSuffix
  , hasWorkers
  , checkCounted
  , unboxCheckOn
  )
  where


-- Ficcus, H16 stage 2 slice W7a (docs/H16-RULE2-DESIGN.md): rule 2, the unboxed result of a Known clone (version B: single clone SCCs).
--
-- A Known clone (clone id >= `base`: the first id Known could hand out) whose result is a custom type and whose every tail leaf is a
-- constructor application, a tail call of another worker, or the forwarding of a let bound worker call that is only matched, gets a WORKER
-- `f_w` that returns the result as a flat struct `{slots}` (the tag and the leaves of the fields of every constructor, shared by leaf class,
-- unused slots filled with the sentinel `fic_nul0` (reference slots, counted) or 0). The original clone stays as a WRAPPER that calls the
-- worker and builds the cell. A `case f args of ..` whose alternatives are plain constructor patterns calls the worker and matches the slots
-- (the struct dies at the match, so the Rc pass takes it apart with `MUnpack`: no cell, no State box, no dup of the fields).
--
-- Identity after unpack: a reference filler slot of a matched worker result that the branch does not use is the sentinel with one count; a
-- tail constructor leaf of the branch takes it for its own filler slot (a move) instead of dropping it and counting a fresh one.
--
-- Runs only with `--rc`, between Inline and Twin. Switches (environment): FICCUS_S2_UNBOX_ACYCLIC=1 turns the rule on (until the gates are
-- green it is off by default); FICCUS_S2_NO_UNBOX_IDENT=1 (no filler forwarding); FICCUS_S2_UNBOX_NOVEC=1 (refuse results whose constructors
-- have a Vector or Array field); FICCUS_UNBOX_STATS=1 (analysis, also with the rule off: a line per candidate); FICCUS_UNBOX_CHECK=1 (structural
-- checks of the result, failing the compile).


import Control.Monad (forM, when)
import Control.Monad.State.Strict (State, get, modify', put, runState)
import qualified Data.Graph as Graph
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Set as Set
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)

import Ficcus.Mono.Class
import Ficcus.Mono.Ir
import Ficcus.Mono.Layout (leavesOf)


envIs :: String -> Bool
envIs name = unsafePerformIO (fmap (== Just "1") (lookupEnv name))

-- | the rule is on with FICCUS_S2_UNBOX_ACYCLIC=1, off with =0 or FICCUS_S2_NO_UNBOX=1; unset: `unboxDefault` (on since the gates of W7a are green)
{-# NOINLINE unboxOn #-}
unboxOn :: Bool
unboxOn = unsafePerformIO (fmap decide (lookupEnv "FICCUS_S2_UNBOX_ACYCLIC"))
  where decide v = case v of { Just "1" -> not (envIs "FICCUS_S2_NO_UNBOX"); Just "0" -> False; _ -> unboxDefault && not (envIs "FICCUS_S2_NO_UNBOX") }

unboxDefault :: Bool
unboxDefault = True

{-# NOINLINE identOn #-}
identOn :: Bool
identOn = not (envIs "FICCUS_S2_NO_UNBOX_IDENT")

{-# NOINLINE noVecOn #-}
noVecOn :: Bool
noVecOn = envIs "FICCUS_S2_UNBOX_NOVEC"

{-# NOINLINE checkOn #-}
checkOn :: Bool
checkOn = envIs "FICCUS_UNBOX_CHECK"

unboxCheckOn :: Bool
unboxCheckOn = checkOn

{-# NOINLINE statsOn #-}
statsOn :: Bool
statsOn = envIs "FICCUS_UNBOX_STATS"


-- | the name suffix of a worker clone (the C generator emits the sentinel exit check in programs that have one)
workerSuffix :: String
workerSuffix = "~unbox"

hasWorkers :: MProgram -> Bool
hasWorkers p = any (\d -> workerSuffix `List.isSuffixOf` mdName d) (mpClones p)


data UnboxResult = UnboxResult
  { urProgram :: MProgram
  , urStats :: [String]
  , urErrors :: [String]
  }


-- LEAVES ---------------------------------------------------------------------------------------------------------------------------------

data Leaf
  = LCtor String Int (Maybe Key) [Class]   -- constructor, tag, key (Nothing: a forwarded constructor of a case alternative), classes of the arguments
  | LCall CloneId                     -- a tail call of a clone (also the forwarding of a whole matched result)
  | LNeed CloneId                     -- the clone must be a worker (a let bound call whose case is rewritten, so that its results can be forwarded)
  | LBad String                       -- anything else: the clone is refused


-- | `let v = g args in case v of alts` where `v` is used only as the scrutinee and as a tail leaf of the alternatives (rule 1c output)
fwdLet :: MExpr -> Maybe (String, MExpr, [MExpr], [(MPat, MExpr)])
fwdLet e =
  case mNode e of
    MLetVal v call body
      | MCall h args <- mNode call, MGlobal _ <- mNode h
      , MCase s alts <- mNode body, MLocal v' <- mNode s, v' == v
      , isJust (altsOf alts)
      , occurrences v body == 1 + sum [ tailOcc v b | (_, b) <- alts ] -> Just (v, h, args, alts)
    _ -> Nothing


occurrences :: String -> MExpr -> Int
occurrences v e =
  case mNode e of
    MLocal n | n == v -> 1
    _ -> sum (map (occurrences v) (children e))


-- the occurrences of `v` in tail positions
tailOcc :: String -> MExpr -> Int
tailOcc v e =
  case mNode e of
    MLocal n | n == v -> 1
    MLetVal _ _ b -> tailOcc v b
    MSeq _ b -> tailOcc v b
    MIf bs el -> sum [ tailOcc v b | (_, b) <- bs ] + tailOcc v el
    MCase _ bs -> sum [ tailOcc v b | (_, b) <- bs ]
    _ -> 0


-- | an alternative of a case on a worker result: a constructor pattern with variable or wildcard arguments, or the last wildcard
data AltK = AltK { akTag :: Maybe Int, akVars :: [(Maybe String, Class)], akBody :: MExpr }


altsOf :: [(MPat, MExpr)] -> Maybe [AltK]
altsOf alts =
  do  xs <- mapM one alts
      let lastOk = and [ akTag a /= Nothing | a <- take (length xs - 1) xs ]
      if lastOk && not (null xs) then Just xs else Nothing
  where
    one (MPat _ (PCtor _ t ps), b) = do { vs <- mapM field ps; Just (AltK (Just t) vs b) }
    one (MPat _ PWild, b) = Just (AltK Nothing [] b)
    one _ = Nothing
    field (MPat c (PVar v)) = Just (Just v, c)
    field (MPat c PWild) = Just (Nothing, c)
    field _ = Nothing


data FwdL = FAll CloneId | FCtor String Int [Class]


leavesOfBody :: Map.Map CloneId MDef -> MExpr -> [Leaf]
leavesOfBody defs = go Map.empty
  where
    callee h args =
      case mNode h of
        MGlobal g | Just d <- Map.lookup g defs, length args == length (mdParams d) -> Just g
        _ -> Nothing
    altFwd _ (MPat _ (PCtor n t ps)) = FCtor n t (map mpRep ps)
    altFwd g _ = FAll g
    go fwd e
      | Just (v, h, args, alts) <- fwdLet e, Just g <- callee h args =
          LNeed g : concat [ go (Map.insert v (altFwd g p) fwd) b | (p, b) <- alts ]
      | otherwise =
          case mNode e of
            MLetVal _ _ b -> go fwd b
            MSeq _ b -> go fwd b
            MIf bs el -> concat [ go fwd b | (_, b) <- bs ] ++ go fwd el
            MCase _ bs -> concat [ go fwd b | (_, b) <- bs ]
            MCall h args
              | MCtor n t k <- mNode h -> [LCtor n t (Just k) (map mRep args)]
              | Just g <- callee h args -> [LCall g]
              | otherwise -> [LBad "call of something else"]
            MCtor n t k -> [LCtor n t (Just k) []]
            MLocal v | Just (FAll g) <- Map.lookup v fwd -> [LCall g]
                     | Just (FCtor n t cs) <- Map.lookup v fwd -> [LCtor n t Nothing cs]
                     | otherwise -> [LBad "a variable"]
            MLit _ -> [LBad "a literal"]
            MGlobal _ -> [LBad "a global value"]
            MKernel _ _ -> [LBad "a kernel"]
            _ -> [LBad "another expression"]


-- LAYOUT ---------------------------------------------------------------------------------------------------------------------------------

data Ctor = Ctor
  { cName :: String
  , cTag :: Int
  , cKey :: Key
  , cFields :: [Class]
  , cSlots :: [Int]                    -- the slot (index into lAll) of each leaf of the fields, in order
  }

data Layout = Layout
  { lAll :: [Class]                    -- the classes of the struct fields: slots by leaf class, the tag among the enum slots
  , lTag :: Int                        -- the index of the tag
  , lCtors :: Map.Map Int Ctor
  , lWords :: Int
  }


lRes :: Layout -> Class
lRes l = CStruct (lAll l)


classOrder :: [Class]
classOrder = [CRef, CI64, CF64, CU32, CEnum, CUnit]


sizeOf :: Class -> Int
sizeOf c = case c of { CRef -> 8; CI64 -> 8; CF64 -> 8; CU32 -> 4; _ -> 1 }


-- | the layout for a set of constructors: a slot per leaf class and occurrence, shared by the constructors
mkLayout :: [(String, Int, Maybe Key, [Class])] -> Either String Layout
mkLayout [] = Left "no constructor leaf in the family"
mkLayout ctors0 =
  do  ctors <- merge ctors0
      let leafCls (_, _, _, fs) = concatMap leavesOf fs
          count x ct = length (filter (== x) (leafCls ct))
          need x = maximum (0 : map (count x) ctors) + (if x == CEnum then 1 else 0)
          order = concat [ replicate (need x) x | x <- classOrder ]
          -- the first enum slot is the tag
          start x = length (concat [ replicate (need y) y | y <- takeWhile (/= x) classOrder ])
          tagIx = start CEnum
          slotOf x i = start x + (if x == CEnum then 1 else 0) + i
          boxedC c = case c of { CStruct _ -> CRef; _ -> c }
          mk ct@(n, t, mk', fs) =
            let ls = leafCls ct
                idx = [ slotOf x (length (filter (== x) (take j ls))) | (j, x) <- zip [0 :: Int ..] ls ]
            in (t, Ctor n t (fromMaybe (Key (map (ByClass . boxedC) fs)) mk') fs idx)
          bytes = foldl (\off c -> let a = sizeOf c in ((off + a - 1) `div` a) * a + a) 0 order
          words' = (bytes + 7) `div` 8
      if words' > 8 then Left ("slot words " ++ show words') else Right (Layout order tagIx (Map.fromList (map mk ctors)) words')
  where
    merge xs = go [] xs
    go acc [] = Right (reverse acc)
    go acc (c@(n, t, k, fs) : rest) =
      case [ o | o@(_, t', _, _) <- acc, t' == t ] of
        [] -> go (c : acc) rest
        (n', _, k', fs') : _ | n' == n, fs' == fs, k' == k || k == Nothing || k' == Nothing ->
                                 go (if k' == Nothing && k /= Nothing then [ if t'' == t then c else o | o@(_, t'', _, _) <- acc ] else acc) rest
                             | otherwise -> Left ("constructor conflict at tag " ++ show t ++ " (" ++ n ++ " " ++ show fs ++ " against " ++ n' ++ " " ++ show fs' ++ ")")


-- CANDIDATES -----------------------------------------------------------------------------------------------------------------------------

data Worker = Worker
  { wOrig :: CloneId
  , wId :: CloneId
  , wLay :: Layout
  , wFam :: Int
  , wArity :: Int
  }


-- | the analysis: the workers (original id -> worker), the refusal reasons of every other candidate, and the family of each worker
analyse :: Int -> MProgram -> (Map.Map CloneId Worker, [(CloneId, String)])
analyse base prog = (workers, refusals)
  where
    clones = mpClones prog
    defs = Map.fromList [ (mdClone d, d) | d <- clones ]
    comps = Graph.stronglyConnComp [ (mdClone d, mdClone d, maybe [] exprRefs (mdBody d)) | d <- clones ]
    bigCycle = Set.fromList (concat [ cs | Graph.CyclicSCC cs <- comps, length cs > 1 ])
    isKnown d = let CloneId n = mdClone d in n >= base
    candidates = [ d | d <- clones, isKnown d, mdKind d == Function, isJust (mdBody d), mdResult d == CRef, Just (mdClone d) /= mpMain prog ]
    leafInfo = Map.fromList [ (mdClone d, leavesOfBody defs b) | d <- candidates, Just b <- [mdBody d] ]
    firstReason c =
      case Map.lookup c leafInfo of
        Just ls | (r : _) <- [ x | LBad x <- ls ] -> Just ("leaf: " ++ r)
                | null [ () | LCtor _ _ _ _ <- ls ] && null [ () | LCall _ <- ls ] -> Just "no constructor leaf"
        _ -> Nothing
    base0 = Map.fromList
      [ (mdClone d, why)
      | d <- candidates
      , let c = mdClone d
      , let why | Set.member c bigCycle = Just "in a call cycle (B)"
                | Just r <- firstReason c = Just r
                | otherwise = Nothing ]
    -- the fixpoint: refuse a clone whose tail callee is refused; then the layouts per family, refusing families that do not fit
    loop refused =
      let alive = [ c | (c, Nothing) <- Map.toList (Map.union refused (Map.map (const Nothing) leafInfo)) ]
          aliveSet = Set.fromList alive
          callRefusals = [ (c, "tail callee " ++ show' g ++ " is not a worker")
                         | c <- alive, Just ls <- [Map.lookup c leafInfo], g <- [ x | LCall x <- ls ] ++ [ x | LNeed x <- ls ], not (Set.member g aliveSet) ]
          fams = families alive
          famRefusals = [ (c, why) | (cs, ls) <- fams, Left why <- [mkLayout (famCtors ls)], c <- cs ]
          famCtors ls = [ (n, t, k, fs) | LCtor n t k fs <- ls ]
          vecRefusals = if noVecOn then [ (c, "a Vector or Array field") | (cs, ls) <- fams, hasVec (famCtors ls), c <- cs ] else []
          new = Map.fromListWith (\_ x -> x) [ (c, Just w) | (c, w) <- callRefusals ++ famRefusals ++ vecRefusals ]
          refused' = Map.union new refused
      in if Map.null new then (refused, fams) else loop refused'
    hasVec cs = or [ any (\f -> f == CRef && isVecCtor n t) fs | (n, t, _, fs) <- cs ]
    isVecCtor n t = any (\u -> any (\(n', t', ts) -> n' == n && t' == t && any mentionsVec ts) (usCtors u)) (Map.elems (mpUnions prog))
    mentionsVec ty = case ty of
      TyCon nm as -> "Vector" `List.isInfixOf` nm || "Array" `List.isInfixOf` nm || any mentionsVec as
      TyFun a b -> mentionsVec a || mentionsVec b
      TyRecord fs -> any (mentionsVec . snd) fs
      TyTuple xs -> any mentionsVec xs
      TyUnit -> False
    show' (CloneId n) = "c" ++ show n
    -- families: connected components of the tail call graph among the live clones
    families alive =
      let aliveSet = Set.fromList alive
          edges = [ (c, g) | c <- alive, Just ls <- [Map.lookup c leafInfo], LCall g <- ls, Set.member g aliveSet ]
          adj c = [ g | (a, g) <- edges, a == c ] ++ [ a | (a, g) <- edges, g == c ]
          comps' = Graph.stronglyConnComp [ (c, c, adj c) | c <- alive ]
          groups = [ case x of { Graph.AcyclicSCC c -> [c]; Graph.CyclicSCC cs -> cs } | x <- comps' ]
      in [ (cs, concat [ fromMaybe [] (Map.lookup c leafInfo) | c <- cs ]) | cs <- groups ]
    (refusedFinal, famsFinal) = loop (Map.map id base0)
    nextId = 1 + maximum (0 : [ n | d <- clones, let CloneId n = mdClone d ])
    famList = [ (cs, l) | (cs, ls) <- famsFinal, Right l <- [mkLayout [ (n, t, k, fs) | LCtor n t k fs <- ls ]] ]
    assigned = zip [0 :: Int ..] famList
    workerIds = zip (concat [ cs | (_, (cs, _)) <- assigned ]) [nextId ..]
    workers = Map.fromList
      [ (c, Worker c (CloneId wid) l fi (maybe 0 (length . mdParams) (Map.lookup c defs)))
      | (fi, (cs, l)) <- assigned, c <- cs, Just wid <- [lookup c workerIds] ]
    refusals = [ (c, why) | (c, Just why) <- Map.toList refusedFinal ]


-- REWRITING ------------------------------------------------------------------------------------------------------------------------------

type U = State (Int, Map.Map String Int)

freshN :: String -> U String
freshN stem = do { (k, m) <- get; put (k + 1, m); return (stem ++ "@@" ++ show k) }

bump :: String -> U ()
bump key = modify' (\(k, m) -> (k, Map.insertWith (+) key 1 m))


newtype Cx = Cx { cxWork :: Map.Map CloneId Worker }

-- | in the tail positions of a worker: the reference filler slots the branch may take for its own fillers, and the forwardable variables
data Env = Env
  { eFill :: [String]
  , eFwd :: Map.Map String Fwd
  }

-- | what the let bound scrutinee `v` stands for in an alternative: the whole matched struct (a default alternative), or the constructor of the
-- alternative with the arguments rebuilt from its slots
data Fwd = FwdAll [MExpr] | FwdCtor String Int [MExpr]

emptyEnv :: Env
emptyEnv = Env [] Map.empty

type Rec = Env -> MExpr -> U MExpr


local :: Class -> String -> MExpr
local c n = MExpr c (MLocal n)


mapChildren :: (MExpr -> U MExpr) -> MExpr -> U MExpr
mapChildren go (MExpr c node) = MExpr c <$>
  case node of
    MCall f args -> MCall <$> go f <*> mapM go args
    MLam ps b -> MLam ps <$> go b
    MIf arms el -> MIf <$> mapM (\(a, b) -> (,) <$> go a <*> go b) arms <*> go el
    MLetVal x v b -> MLetVal x <$> go v <*> go b
    MSeq a b -> MSeq <$> go a <*> go b
    MCase sc bs -> MCase <$> go sc <*> mapM (\(p, b) -> (,) p <$> go b) bs
    MAccess x f i -> (\x' -> MAccess x' f i) <$> go x
    MUpdate x fs -> MUpdate <$> go x <*> mapM (\(f, v) -> (,) f <$> go v) fs
    MRecord fs -> MRecord <$> mapM (\(f, v) -> (,) f <$> go v) fs
    MTuple xs -> MTuple <$> mapM go xs
    MList xs -> MList <$> mapM go xs
    _ -> pure node


-- | a call of a worker's original clone with all its arguments
workerCall :: Cx -> MExpr -> Maybe (Worker, MExpr, [MExpr])
workerCall cx e =
  case mNode e of
    MCall h args | MGlobal g <- mNode h, Just w <- Map.lookup g (cxWork cx), length args == wArity w -> Just (w, h, args)
    _ -> Nothing


-- | no tail conversion: only the sites, in any position
rwNT :: Cx -> MExpr -> U MExpr
rwNT cx e =
  case mNode e of
    MCase s alts
      | Just (w, h, args) <- workerCall cx s, Just aks <- altsOf alts ->
          do  bump "sites"
              site cx (\_ b -> rwNT cx b) emptyEnv (mRep e) Nothing w h args aks
    _ -> mapChildren (rwNT cx) e


-- | a tail position of the worker `cur`
rwTL :: Cx -> Worker -> Rec
rwTL cx cur env e =
  case fwdLet e of
    Just (v, h, args, alts)
      | MGlobal g <- mNode h, Just w <- Map.lookup g (cxWork cx), length args == wArity w, Just aks <- altsOf alts ->
          do  bump "sites"
              bump "forward sites"
              site cx self env rc (Just v) w h args aks
    _ ->
      case mNode e of
        MLetVal n v b -> do { v' <- rwNT cx v; b' <- self env b; return (retag (MLetVal n v' b')) }
        MSeq a b -> do { a' <- rwNT cx a; b' <- self env b; return (retag (MSeq a' b')) }
        MIf bs el ->
          do  bs' <- mapM (\(c, b) -> (,) <$> rwNT cx c <*> self env b) bs
              el' <- self env el
              return (retag (MIf bs' el'))
        MCase s alts
          | Just (w, h, args) <- workerCall cx s, Just aks <- altsOf alts ->
              do  bump "sites"
                  site cx self env rc Nothing w h args aks
          | otherwise ->
              do  s' <- rwNT cx s
                  alts' <- mapM (\(p, b) -> (,) p <$> self env b) alts
                  return (retag (MCase s' alts'))
        MCall h args
          | MCtor n t k <- mNode h -> leafCtor cx lay env n t k args
          | Just (w, h', args') <- workerCall cx e ->
              do  when (wFam w /= wFam cur) (bump "ERROR family mismatch")
                  args'' <- mapM (rwNT cx) args'
                  bump "tail calls"
                  return (retag (MCall (MExpr (mRep h') (MGlobal (wId w))) args''))
        MCtor n t k -> leafCtor cx lay env n t k []
        MLocal v | Just (FwdAll slots) <- Map.lookup v (eFwd env) ->
          do  bump "forwarded results"
              return (retag (MTuple slots))
                 | Just (FwdCtor n t as) <- Map.lookup v (eFwd env) ->
          do  bump "forwarded constructors"
              leafCtor cx lay env n t (Key []) as
        _ -> do { bump ("ERROR unconverted tail leaf in c" ++ (let CloneId n = wOrig cur in show n) ++ ": " ++ take 60 (show (mNode e))); return e }
  where
    lay = wLay cur
    rc = lRes lay
    self = rwTL cx cur
    retag node = MExpr rc node


-- | a tail constructor leaf: the struct of the worker's family
leafCtor :: Cx -> Layout -> Env -> String -> Int -> Key -> [MExpr] -> U MExpr
leafCtor cx lay env _n t _k args =
  case Map.lookup t (lCtors lay) of
    Nothing -> bump "ERROR constructor not in layout" >> return (MExpr (lRes lay) (MTuple []))
    Just ct ->
      flatten cx args $ \leaves ->
        do  let assigned = Map.fromList (zip (cSlots ct) leaves)
                refSlots = [ j | (j, c) <- zip [0 :: Int ..] (lAll lay), c == CRef, not (Map.member j assigned), j /= lTag lay ]
                pool = if identOn then eFill env else []
                forwarded = Map.fromList (zip refSlots pool)
            mapM_ (const (bump "filler forwards")) (Map.elems forwarded)
            mapM_ (const (bump "fresh filler")) (drop (length pool) refSlots)
            let slot j c
                  | j == lTag lay = MExpr CEnum (MLit (LInt (fromIntegral t)))
                  | Just x <- Map.lookup j assigned = x
                  | c == CRef, Just v <- Map.lookup j forwarded = local CRef v
                  | otherwise = filler c
            return (MExpr (lRes lay) (MTuple [ slot j c | (j, c) <- zip [0 ..] (lAll lay) ]))


filler :: Class -> MExpr
filler c =
  case c of
    CRef -> MExpr CRef (MCtor "#filler" 0 (Key []))
    CF64 -> MExpr c (MLit (LFloat 0))
    CU32 -> MExpr c (MLit (LChar 0))
    CUnit -> MExpr c (MLit LUnit)
    _ -> MExpr c (MLit (LInt 0))


-- | the arguments of a constructor as atoms, one per leaf, in order (the arguments are evaluated in order, as in the cell). A struct inside a
-- struct is a boxed leaf (a reference), as the class of the container says; the expression keeps its own class and the generator adapts it.
flatten :: Cx -> [MExpr] -> ([MExpr] -> U MExpr) -> U MExpr
flatten cx args0 k0 = many [ (a, mRep a) | a <- args0 ] k0
  where
    many [] k = k []
    many ((a, c) : rest) k = one a c (\ls -> many rest (\more -> k (ls ++ more)))
    one a c k =
      case c of
        CStruct fs ->
          case mNode a of
            MRecord xs | length xs == length fs -> many (zip (map snd xs) fs) k
            MTuple xs | length xs == length fs -> many (zip xs fs) k
            MLetVal x v b ->
              do  v' <- rwNT cx v
                  inner <- one b c k
                  return (MExpr (mRep inner) (MLetVal x v' inner))
            _ ->
              do  a' <- rwNT cx a
                  (bindIt, s) <- case mNode a' of
                                   MLocal n -> return (id, n)
                                   _ -> do { t <- freshN "ubv"; return (\b -> MExpr (mRep b) (MLetVal t a' b), t) }
                  (pat, vars) <- patOf c
                  inner <- k vars
                  return (bindIt (MExpr (mRep inner) (MCase (local c s) [(pat, inner)])))
        _ ->
          do  a' <- rwNT cx a
              case mNode a' of
                MLocal _ -> k [a']
                MLit _ -> k [a']
                MCtor _ _ _ -> k [a']
                _ -> do { t <- freshN "ubv"; inner <- k [local (mRep a') t]; return (MExpr (mRep inner) (MLetVal t a' inner)) }
    -- a pattern that binds every leaf of a struct class to a variable
    patOf c =
      case c of
        CStruct fs ->
          do  parts <- mapM patOf fs
              return (MPat c (PTuple (map fst parts)), concatMap snd parts)
        _ -> do { v <- freshN "ubl"; return (MPat c (PVar v), [local c v]) }


-- | a case on a worker call: the worker is called, the slots are bound, the tag selects the alternative
site :: Cx -> Rec -> Env -> Class -> Maybe String -> Worker -> MExpr -> [MExpr] -> [AltK] -> U MExpr
site cx rec env cls fwdVar w h args alts =
  do  let lay = wLay w
      names <- forM (zip [0 :: Int ..] (lAll lay)) (\(j, _) -> freshN (if j == lTag lay then "ubt" else "ubs"))
      let slotsE = [ local c n | (c, n) <- zip (lAll lay) names ]
          tagV = names !! lTag lay
          fwdAll = maybe (eFwd env) (\v -> Map.insert v (FwdAll slotsE) (eFwd env)) fwdVar
      args' <- mapM (rwNT cx) args
      parts <- forM alts $ \ak ->
        case akTag ak of
          Nothing ->
            do  b <- rec env { eFill = [], eFwd = fwdAll } (akBody ak)
                return [(Nothing, b)]
          Just t | Just ct <- Map.lookup t (lCtors lay) ->
            do  let mine = Set.fromList (cSlots ct)
                    fills = [ names !! j | (j, c) <- zip [0 ..] (lAll lay), c == CRef, j /= lTag lay, not (Set.member j mine) ]
                    fieldLeaves = splitLeaves (cFields ct) [ slotsE !! j | j <- cSlots ct ]
                    argsOf = [ rebuild c ls | (c, ls) <- zip (cFields ct) fieldLeaves ]
                    fwdK = maybe (eFwd env) (\v -> Map.insert v (FwdCtor (cName ct) t argsOf) (eFwd env)) fwdVar
                b <- rec env { eFill = fills, eFwd = fwdK } (akBody ak)
                -- the fields: the pattern variables take the slots of the constructor
                let binds = [ (x, c, leaves) | ((Just x, c), leaves) <- zip (akVars ak) fieldLeaves, occurs x b ]
                    b' = foldr (\(x, c, leaves) acc -> MExpr (mRep acc) (MLetVal x (rebuild c leaves) acc)) b binds
                return [(Just t, b')]
          Just _ -> return []
      let alts' = concat parts
          dispatch =
            case alts' of
              [(_, b)] -> b
              _ -> MExpr cls (MCase (local CEnum tagV)
                                [ (MPat CEnum (case mt of { Just t | i < length alts' - 1 -> PCtor "#tag" t []; _ -> PWild }), b)
                                | (i, (mt, b)) <- zip [0 :: Int ..] alts' ])
          callE = MExpr (lRes lay) (MCall (MExpr (mRep h) (MGlobal (wId w))) args')
      return (MExpr cls (MCase callE [(slotPattern lay names dispatch, dispatch)]))


slotPattern :: Layout -> [String] -> MExpr -> MPat
slotPattern lay names body =
  MPat (lRes lay) (PTuple [ MPat c (if occurs n body then PVar n else PWild) | (c, n) <- zip (lAll lay) names ])


occurs :: String -> MExpr -> Bool
occurs n e =
  case mNode e of
    MLocal m -> m == n
    _ -> any (occurs n) (children e)


-- | cut a flat list of leaf expressions into the leaves of each field
splitLeaves :: [Class] -> [MExpr] -> [[MExpr]]
splitLeaves [] _ = []
splitLeaves (f : fs) xs = let n = length (leavesOf f) in take n xs : splitLeaves fs (drop n xs)


-- | rebuild a value of class `c` from its leaves (a struct from nested tuples)
rebuild :: Class -> [MExpr] -> MExpr
rebuild c leaves = fst (go c leaves)
  where
    go cls xs =
      case cls of
        CStruct fs ->
          let (parts, rest) = foldl (\(acc, ys) f -> let (p, ys') = go f ys in (acc ++ [p], ys')) ([], xs) fs
          in (MExpr cls (MTuple parts), rest)
        _ -> case xs of { x : rest -> (x, rest); [] -> (filler cls, []) }


-- THE PROGRAM ----------------------------------------------------------------------------------------------------------------------------

unboxProgram :: Int -> MProgram -> UnboxResult
unboxProgram base prog
  | not unboxOn && not statsOn = UnboxResult prog [] []
  | otherwise = UnboxResult prog' stats errs
  where
    (workers, refusals) = analyse base prog
    clones = mpClones prog
    defs = Map.fromList [ (mdClone d, d) | d <- clones ]
    cx = Cx workers
    (converted, (_, counters)) = runState (mapM convert clones) (0, Map.empty)
    newClones = concat converted
    prog' = if unboxOn && not (Map.null workers) then prog { mpClones = newClones } else prog
    convert :: MDef -> U [MDef]
    convert d =
      case (mdBody d, Map.lookup (mdClone d) workers) of
        (Just b, Just w) ->
          do  wb <- rwTL cx w emptyEnv b
              let wd = d { mdClone = wId w, mdName = mdName d ++ workerSuffix, mdResult = lRes (wLay w), mdBody = Just wb, mdOwn = [], mdTwin = Nothing, mdCapsOwned = False }
              wrap <- wrapper w d
              return [wd, wrap]
        (Just b, Nothing) -> do { b' <- rwNT cx b; return [d { mdBody = Just b' }] }
        _ -> return [d]
    wrapper w d =
      do  let lay = wLay w
          names <- forM (zip [0 :: Int ..] (lAll lay)) (\(j, _) -> freshN (if j == lTag lay then "ubt" else "ubs"))
          let slotsE = [ local c n | (c, n) <- zip (lAll lay) names ]
              tagV = names !! lTag lay
              callE = MExpr (lRes lay) (MCall (MExpr CRef (MGlobal (wId w))) [ local c n | (n, c) <- mdParams d ])
              alt ct =
                let leaves = splitLeaves (cFields ct) [ slotsE !! j | j <- cSlots ct ]
                    fieldsE = [ rebuild c ls | (c, ls) <- zip (cFields ct) leaves ]
                in if null fieldsE then MExpr CRef (MCtor (cName ct) (cTag ct) (Key []))
                   else MExpr CRef (MCall (MExpr CRef (MCtor (cName ct) (cTag ct) (cKey ct))) fieldsE)
              cts = Map.elems (lCtors lay)
              dispatch = case cts of
                [ct] -> alt ct
                _ -> MExpr CRef (MCase (local CEnum tagV)
                                  [ (MPat CEnum (if i < length cts - 1 then PCtor "#tag" (cTag ct) [] else PWild), alt ct) | (i, ct) <- zip [0 :: Int ..] cts ])
          return d { mdBody = Just (MExpr CRef (MCase callE [(slotPattern lay names dispatch, dispatch)])), mdOwn = [], mdTwin = Nothing }
    errs = if not unboxOn then [] else (if checkOn then checkWorkers workers newClones else []) ++
           [ "unbox: internal error: " ++ k ++ " (" ++ show v ++ "x)" | (k, v) <- Map.toList counters, take 5 k == "ERROR" ]
    cname (CloneId n) = "c" ++ show n
    nameOf c = maybe "?" mdName (Map.lookup c defs)
    classTag' c = case c of { CRef -> "p"; CI64 -> "i"; CF64 -> "d"; CU32 -> "c"; CEnum -> "e"; CUnit -> "u"; CStruct _ -> "S" }
    stats =
      [ "FICCUS_UNBOX_STATS: workers " ++ show (Map.size workers) ++ ", refused " ++ show (length refusals) ++ ", base " ++ show base ]
      ++ [ "UNBOX worker " ++ cname c ++ " " ++ nameOf c ++ " as " ++ cname (wId w) ++ " family " ++ show (wFam w) ++ " slots " ++ show (length (lAll (wLay w)))
             ++ " words " ++ show (lWords (wLay w)) ++ " classes " ++ concatMap classTag' (lAll (wLay w))
         | (c, w) <- Map.toList workers ]
      ++ [ "UNBOX refused " ++ cname c ++ " " ++ nameOf c ++ ": " ++ why | (c, why) <- refusals ]
      ++ [ "UNBOX counter " ++ k ++ " " ++ show v | (k, v) <- Map.toList counters ]
      ++ (if unboxOn then wrapperUses else [])
    wrapperUses =
      let uses = concat [ useKinds b | d <- newClones, Just b <- [mdBody d], not (isWrapper d) ]
          isWrapper d = any (\w -> mdClone d == wOrig w) (Map.elems workers)
          useKinds b =
            case mNode b of
              MCall h args | MGlobal g <- mNode h, Map.member g workers -> (g, "call") : concatMap useKinds args
              MGlobal g | Map.member g workers -> [(g, "value")]
              _ -> concatMap useKinds (children b)
      in [ "UNBOX wrapper uses " ++ cname g ++ " calls " ++ show (length [ () | (g', "call") <- uses, g' == g ])
             ++ " values " ++ show (length [ () | (g', "value") <- uses, g' == g ])
         | g <- Map.keys workers ]


-- | FICCUS_UNBOX_CHECK: a worker is referred to only as the scrutinee of a case with one tuple pattern that binds every slot with its class,
-- or as a tail leaf of a worker of the same family; every worker body leaf has the result class of the worker
checkWorkers :: Map.Map CloneId Worker -> [MDef] -> [String]
checkWorkers workers clones = concatMap check clones
  where
    byWorker = Map.fromList [ (wId w, w) | w <- Map.elems workers ]
    check d =
      case mdBody d of
        Nothing -> []
        Just b ->
          let me = Map.lookup (mdClone d) byWorker
              errs = walk (isJust me) me b
          in [ "unbox check (" ++ mdName d ++ "): " ++ e | e <- errs ]
    isW e = case mNode e of { MCall h _ | MGlobal g <- mNode h, Map.member g byWorker -> Just g; _ -> Nothing }
    walk tl me e =
      case mNode e of
        MCase s alts
          | Just g <- isW s, Just w <- Map.lookup g byWorker ->
              let ok = case alts of
                         [(MPat c (PTuple ps), _)] -> c == lRes (wLay w) && map mpRep ps == lAll (wLay w) && all plain ps
                         _ -> False
                  plain p = case mpNode p of { PVar _ -> True; PWild -> True; _ -> False }
              in [ "a worker call is not matched by one tuple pattern of its slots" | not ok ]
                 ++ concat [ walk False me a | a <- callArgs s ]
                 ++ concat [ walk tl me b | (_, b) <- alts ]
        MCall _ args
          | Just g <- isW e ->
              [ "a worker call outside a case and not in a tail position of a worker" | not tl ]
              ++ [ "a tail call of a worker of another family" | tl, Just w <- [Map.lookup g byWorker], Just w' <- [me], wFam w /= wFam w' ]
              ++ [ "a tail call whose class is not the result class" | tl, Just w' <- [me], mRep e /= lRes (wLay w') ]
              ++ concat [ walk False me a | a <- args ]
        MTuple _ | tl, Just w <- me, mRep e /= lRes (wLay w) -> ["a tail tuple of the wrong class"]
        MLetVal _ v b -> walk False me v ++ walk tl me b
        MSeq a b -> walk False me a ++ walk tl me b
        MIf bs el -> concat [ walk False me c ++ walk tl me b | (c, b) <- bs ] ++ walk tl me el
        MCase s alts -> walk False me s ++ concat [ walk tl me b | (_, b) <- alts ]
        _ -> concatMap (walk False me) (children e)
    callArgs x = case mNode x of { MCall _ as -> as; _ -> [] }


-- | FICCUS_UNBOX_CHECK, after the Rc pass: every call of a worker that is let bound and matched (the form that `case f_w .. of` takes in the counted
-- program) must be matched by a branch that is an `MUnpack` of the result (the struct dies at the match: no dup of a field, no drop of a cell); a
-- worker call anywhere else must be a tail leaf of a worker. Returns (messages, number of unpacked sites)
checkCounted :: MProgram -> ([String], Int)
checkCounted prog = (concat errs, sum counts)
  where
    workerIds = Set.fromList [ mdClone d | d <- mpClones prog, workerSuffix `List.isSuffixOf` mdName d ]
    (errs, counts) = unzip [ (map (\e -> "unbox check (" ++ mdName d ++ ", after Rc): " ++ e) es, n) | d <- mpClones prog, Just b <- [mdBody d], let (es, n) = walk b ]
    isWorkerCall e = case mNode e of { MCall h _ | MGlobal g <- mNode h, Set.member g workerIds -> True; _ -> False }
    walk :: MExpr -> ([String], Int)
    walk e =
      case mNode e of
        MLetVal t v b
          | isWorkerCall v, MCase sc [(_, br)] <- mNode (stripDrops b), MLocal t' <- mNode sc, t' == t ->
              let (es, n) = walk br
              in case mNode br of
                   MUnpack r _ _ inner | r == t -> let (es', n') = walk inner in (es' ++ es0 v, n' + 1)
                   _ -> (["a worker result is matched by a view branch (fields dup'd, the struct dropped)"] ++ es ++ es0 v, n)
        _ -> let rs = map walk (children e) in (concatMap fst rs, sum (map snd rs))
    es0 v = concatMap fst (map walk (children v))
    stripDrops x = case mNode x of { MDrop _ y -> stripDrops y; MDup _ y -> stripDrops y; _ -> x }
