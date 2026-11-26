{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE PatternGuards, DoAndIfThenElse #-}
module Ficcus.Mono.Known
  ( knownProgram
  , knownRun
  , checkScope
  , knownOn
  )
  where


-- Ficcus, H16 stage 1 (docs/H16-DESIGN.md): known function specialization, work items W1 and W2.
--
-- A Mono -> Mono pass that runs before Inline, only with --rc. It has: the switches and counters, the copy kit (a function copied together
-- with its lifted children under one consistent, scope aware renaming), the scope checker (invariant S: wherever a lifted clone is
-- referenced, the variables it captures are bound), rule V (a top level value whose body is a capture-free closure is an alias of that
-- closure), direct calls through let-bound capture-free closures (W1), and (W2) the expansion of closure builders at a call site
-- (`map2 f pa pb`, `oneOf ps`, `succeed 7`: a function whose result is a closure; the copy of the family has the known arguments
-- substituted, so its calls are direct), rule C (a function whose body is a capture-free closure returns it for every argument: its calls
-- are replaced by the closure), rule F (a closed data literal passed to a builder becomes a global value), and the rounds and budgets of
-- section 1.4 of the design note. Specialization of recursive functions by key is W3.
--
-- Switches (environment): FICCUS_NO_KNOWN=1 returns the program unchanged; FICCUS_KNOWN_STATS=1 (read by Make.hs) prints the counters;
-- FICCUS_KNOWN_CHECK=1 runs the scope checker on the result and fails the compile on a violation; FICCUS_KNOWN_BUDGET=n is the largest family
-- (node count) that one expansion copies (default 200); FICCUS_KNOWN_COPYTEST=1 copies every function family once, unused, and checks the
-- copies (a self test of the copy kit); FICCUS_KNOWN_NO_EXPAND=1 turns off expansion, rule C and rule F (the pass is then W1).


import Control.Monad (when)
import Control.Monad.State.Strict (State, get, gets, modify', put, runState)
import Data.Functor.Identity (Identity(..))
import qualified Data.Graph as Graph
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Set as Set
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)
import Text.Read (readMaybe)

import Ficcus.Mono.Class
import Ficcus.Mono.Free (captures, patVars)
import Ficcus.Mono.Ir


{-# NOINLINE knownOn #-}
knownOn :: Bool
knownOn = unsafePerformIO (fmap (/= Just "1") (lookupEnv "FICCUS_NO_KNOWN"))

{-# NOINLINE checkOn #-}
checkOn :: Bool
checkOn = unsafePerformIO (fmap (== Just "1") (lookupEnv "FICCUS_KNOWN_CHECK"))

{-# NOINLINE copyTestOn #-}
copyTestOn :: Bool
copyTestOn = unsafePerformIO (fmap (== Just "1") (lookupEnv "FICCUS_KNOWN_COPYTEST"))

{-# NOINLINE expandOn #-}
expandOn :: Bool
expandOn = unsafePerformIO (fmap (/= Just "1") (lookupEnv "FICCUS_KNOWN_NO_EXPAND"))

-- H16 stage 2 rule 1b (spine specialization): FICCUS_S2_NO_SPINE=1 turns it off
{-# NOINLINE spineOn #-}
spineOn :: Bool
spineOn = unsafePerformIO (fmap (/= Just "1") (lookupEnv "FICCUS_S2_NO_SPINE"))

{-# NOINLINE specOn #-}
specOn :: Bool
specOn = unsafePerformIO (fmap (/= Just "1") (lookupEnv "FICCUS_KNOWN_NO_SPEC"))

{-# NOINLINE specBudget #-}
specBudget :: Int
specBudget = unsafePerformIO (fmap (fromMaybe 300 . (>>= readMaybe)) (lookupEnv "FICCUS_KNOWN_SPEC_BUDGET"))

{-# NOINLINE budget #-}
budget :: Int
budget = unsafePerformIO (fmap (fromMaybe 200 . (>>= readMaybe)) (lookupEnv "FICCUS_KNOWN_BUDGET"))


-- the budgets of section 1.4 of the design note
maxRounds, perOriginMax, programFloor, spineMax, spinePerOriginMax :: Int
maxRounds = 3
perOriginMax = 32
programFloor = 20000
spineMax = 8                 -- rule 1b: the longest static list that is specialized (cells)
spinePerOriginMax = 64       -- rule 1b: spine copies per original function (they do not count against perOriginMax)


data St = St
  { sSuffix :: Int                       -- the copy number: names of a copy end in "@k<n>"
  , sNext :: Int                         -- the next free clone id
  , sStats :: Map.Map String Int
  , sDefs :: Map.Map CloneId MDef        -- the current clones: rewritten originals and copies
  , sNew :: [CloneId]                    -- copies, newest first
  , sFloated :: [MDef]                   -- rule F values, newest first
  , sOrigin :: Map.Map CloneId CloneId   -- copy -> the original it was made from
  , sAlias :: Map.Map CloneId CloneId    -- rule V: Value clone -> the capture-free Function clone it is
  , sConstFn :: Map.Map CloneId CloneId  -- rule C: Function clone -> the capture-free Function clone it returns for every argument
  , sCaps :: Map.Map CloneId [(String, Class)]
  , sPerOrig :: Map.Map CloneId Int      -- expansions per original builder
  , sAdded :: Int                        -- nodes added by copies
  , sStack :: [CloneId]                  -- builders being expanded
  , sMemo :: Map.Map (CloneId, [String]) MExpr   -- expansions with static arguments only
  , sCur :: CloneId                      -- the clone whose body is being rewritten (the owner of new lifted copies)
  , sSpec :: Map.Map (CloneId, [String]) (CloneId, [(String, Class)])
      -- W3: specializations by key (the function, the known function of each argument); the clone and its extra parameters (captured variables)
  , sTails :: Map.Map CloneId CloneId    -- rule 1b: a static list value -> the static list value of its tail
  , sSpineN :: Map.Map CloneId Int       -- rule 1b: spine copies per original function
  }

type K = State St

-- the locals known to be bound to a capture-free closure
type Env = Map.Map String CloneId


bump :: String -> K ()
bump = bumpN 1

bumpN :: Int -> String -> K ()
bumpN n key = modify' (\s -> s { sStats = Map.insertWith (+) key n (sStats s) })

freshId :: K CloneId
freshId = do { s <- get; put s { sNext = sNext s + 1 }; return (CloneId (sNext s)) }

freshSuffix :: K Int
freshSuffix = do { s <- get; put s { sSuffix = sSuffix s + 1 }; return (sSuffix s + 1) }


-- | the pass; Left: the scope checker found a violation
knownProgram :: MProgram -> Either [String] MProgram
knownProgram = fst . knownRun


-- | read only facts about the program before the pass
data Info = Info
  { iRec :: Set.Set CloneId              -- clones on a reference cycle (also a self reference)
  , iBuilder :: Set.Set CloneId          -- functions whose result is a closure made from their arguments
  , iMain :: Maybe CloneId
  , iSize :: Int                         -- size of the program (nodes)
  }


mkInfo :: MProgram -> Info
mkInfo prog = Info recs (builders byId) (mpMain prog) (sum [ nodeCount b | d <- clones, Just b <- [mdBody d] ])
  where
    clones = mpClones prog
    byId = Map.fromList [ (mdClone d, d) | d <- clones ]
    comps = Graph.stronglyConnComp [ (mdClone d, mdClone d, maybe [] exprRefs (mdBody d)) | d <- clones ]
    recs = Set.fromList (concat [ cs | Graph.CyclicSCC cs <- comps ])


-- a function is a builder when its body (after lets) is a closure lifted out of it, or a call of a builder with all its arguments
builders :: Map.Map CloneId MDef -> Set.Set CloneId
builders byId = grow direct
  where
    fns = [ d | d <- Map.elems byId, mdKind d == Function, Just _ <- [mdBody d] ]
    tailOf e = case mNode e of { MLetVal _ _ b -> tailOf b; _ -> e }
    direct = Set.fromList
      [ mdClone d | d <- fns, Just b <- [mdBody d], MGlobal l <- [mNode (tailOf b)]
                  , Just ld <- [Map.lookup l byId], mdKind ld == Function, mdLifted ld == Just (mdClone d) ]
    grow s =
      let more = Set.fromList
            [ mdClone d | d <- fns, Just b <- [mdBody d], MCall h as <- [mNode (tailOf b)], MGlobal c <- [mNode h], Set.member c s
                        , Just cd <- [Map.lookup c byId], length (mdParams cd) == length as ]
          s' = Set.union s more
      in if Set.size s' == Set.size s then s else grow s'


-- | the pass and its counters (empty when the pass is off)
knownRun :: MProgram -> (Either [String] MProgram, [(String, Int)])
knownRun prog
  | not knownOn = (Right prog, [])
  | otherwise = (if null errs then Right prog { mpClones = if safe then out else clones } else Left errs,
                 Map.toList (sStats st) ++ [ ("closed-check-fallback", 1) | not safe ])
  where
    -- the safety net: a result that is not closed (checkClosed) is never used, the program goes on as it was (with FICCUS_KNOWN_CHECK=1 it is an error)
    safe = checkOn || null (checkClosed (iMain info) clones out)
    clones = mpClones prog
    byId0 = Map.fromList [ (mdClone d, d) | d <- clones ]
    info = mkInfo prog
    start = St 0 (1 + maximum (0 : [ n | d <- clones, let CloneId n = mdClone d ])) Map.empty byId0 [] [] Map.empty Map.empty Map.empty
              (captures clones) Map.empty 0 [] Map.empty (CloneId 0) Map.empty Map.empty Map.empty
    ((out, testErrs), st) = runState go start
    go =
      do  terrs <- if copyTestOn then copyTest byId0 (sCaps start) clones else return []
          rounds info 1
          kept <- finalize info prog
          nNew <- gets (\s -> length (sNew s) + length (sFloated s))
          bumpN (length clones + nNew - length kept) "removed"
          return (kept, terrs)
    errs = testErrs ++ (if checkOn then checkScope out ++ checkClosed (iMain info) clones out else [])


rounds :: Info -> Int -> K ()
rounds info n =
  do  before <- progress
      defs0 <- gets (Map.elems . sDefs)
      modify' (\s -> s { sCaps = captures defs0 })
      order <- gets (\s -> postorder (sDefs s))
      mapM_ (rewriteClone info) order
      bump "rounds"
      after <- progress
      when (after /= before && n < maxRounds) (rounds info (n + 1))
  where
    progress = gets (\s -> (Map.size (sAlias s), Map.size (sConstFn s), length (sNew s), length (sFloated s)))


-- callees first (a reference cycle is broken where the walk meets it)
postorder :: Map.Map CloneId MDef -> [CloneId]
postorder defs = reverse (snd (List.foldl' visit (Set.empty, []) (Map.keys defs)))
  where
    visit (seen, acc) c
      | Set.member c seen = (seen, acc)
      | otherwise =
          let (seen', acc') = List.foldl' visit (Set.insert c seen, acc) (refs c)
          in (seen', c : acc')
    refs c = case Map.lookup c defs of
      Just d -> maybe [] exprRefs (mdBody d)
      Nothing -> []


rewriteClone :: Info -> CloneId -> K ()
rewriteClone info c =
  do  md <- gets (Map.lookup c . sDefs)
      case md of
        Just d | Just b <- mdBody d ->
          do  saved <- gets sCur
              modify' (\s -> s { sCur = c })
              b' <- rw info Map.empty b
              let d' = d { mdBody = Just b' }
              modify' (\s -> s { sDefs = Map.insert c d' (sDefs s), sCur = saved })
              noteFacts info d'
        _ -> return ()


-- the capture-free Function clone that `t` is, following aliases
staticCode :: Info -> St -> CloneId -> Maybe CloneId
staticCode info st t0 = go (20 :: Int) t0
  where
    go n t
      | Just t' <- Map.lookup t (sAlias st) = if n > 0 then go (n - 1) t' else Nothing
      | otherwise =
          case Map.lookup t (sDefs st) of
            Just d | mdKind d == Function, isJust (mdBody d), Just t /= iMain info, null (Map.findWithDefault [] t (sCaps st)) -> Just t
            _ -> Nothing


-- rule V and rule C: record what the rewritten clone is
noteFacts :: Info -> MDef -> K ()
noteFacts info d =
  case mdBody d of
    Just b | MGlobal t <- mNode b ->
      do  st <- get
          case staticCode info st t of
            Just code
              | mdKind d == Value -> do { when (not (Map.member (mdClone d) (sAlias st))) (bump "aliases"); modify' (\s -> s { sAlias = Map.insert (mdClone d) code (sAlias s) }) }
              | expandOn && Just (mdClone d) /= iMain info && not (null (mdParams d)) ->
                  do { when (not (Map.member (mdClone d) (sConstFn st))) (bump "constant-functions"); modify' (\s -> s { sConstFn = Map.insert (mdClone d) code (sConstFn s) }) }
            _ -> return ()
    _ -> return ()


-- the final list: floated values first, then the copies, then the originals in their order; unreferenced aliases, copies and floated values
-- and functions that the rewriting left without a user are removed
finalize :: Info -> MProgram -> K [MDef]
finalize _ prog =
  do  st <- get
      let clones = mpClones prog
          defs = sDefs st
          originals = [ Map.findWithDefault d (mdClone d) defs | d <- clones ]
          copies = [ defs Map.! c | c <- reverse (sNew st) ]
          floated = reverse (sFloated st)
          allDefs = floated ++ copies ++ originals
          inputRefs = Set.fromList (concat [ exprRefs b | d <- clones, Just b <- [mdBody d] ] ++ concatMap mdNeeds clones)
          newIds = Set.fromList (map mdClone (floated ++ copies))
          candidate d = Set.member (mdClone d) newIds
                        || Map.member (mdClone d) (sAlias st)
                        || (mdKind d == Function && Set.member (mdClone d) inputRefs && Just (mdClone d) /= mpMain prog)
          byId = Map.fromList [ (mdClone d, d) | d <- allDefs ]
          roots = maybe [] pure (mpMain prog) ++ Map.elems (mpMembers prog) ++ [ mdClone d | d <- allDefs, not (candidate d) ]      -- (A3b) the helpers' member clones
          reach = walk Set.empty roots
          walk seen [] = seen
          walk seen (c : cs)
            | Set.member c seen = walk seen cs
            | otherwise = case Map.lookup c byId of
                Just d -> walk (Set.insert c seen) (maybe [] exprRefs (mdBody d) ++ mdNeeds d ++ cs)
                Nothing -> walk (Set.insert c seen) cs
      return [ d | d <- allDefs, not (candidate d) || Set.member (mdClone d) reach ]


-- THE REWRITE

atomE :: MExpr -> Bool
atomE e = case mNode e of
  MLit _ -> True
  MLocal _ -> True
  MGlobal _ -> True
  MCtor _ _ _ -> True
  _ -> False


rw :: Info -> Env -> MExpr -> K MExpr
rw info env e =
  case mNode e of
    MCall h args ->
      do  args' <- mapM (rw info env) args
          st <- get
          h' <- case mNode h of
                  MGlobal v | Just l <- Map.lookup v (sAlias st) -> do { bump "direct-calls-alias"; return h { mNode = MGlobal l } }
                  MLocal x | Just l <- Map.lookup x env -> do { bump "direct-calls-let"; return h { mNode = MGlobal l } }
                  _ -> rw info env h
          rwCall info env e h' args'
    MGlobal v ->
      do  st <- get
          case Map.lookup v (sAlias st) of
            Just l -> do { bump "value-uses"; return e { mNode = MGlobal l } }
            Nothing -> return e
    MLetVal n v b ->
      do  v' <- rw info env v
          st <- get
          let known = case mNode v' of
                MGlobal l | Just code <- staticCode info st l -> Just code
                _ -> Nothing
              env' = maybe (Map.delete n env) (\l -> Map.insert n l env) known
          b' <- rw info env' b
          return e { mNode = MLetVal n v' b' }
    MCase s bs ->
      do  s' <- rw info env s
          red <- spineCase info s' bs
          case red of
            Just b' -> rw info env b'
            Nothing ->
              do  bs' <- mapM (\(p, b) -> do { b' <- rw info (foldr Map.delete env (patVars p)) b; return (p, b') }) bs
                  return e { mNode = MCase s' bs' }
    MLam ps b -> do { b' <- rw info (foldr (Map.delete . fst) env ps) b; return e { mNode = MLam ps b' } }
    _ -> mapChildrenM (rw info env) e


-- RULE 1b (H16 stage 2, docs/STAGE2-W6.md): spine specialization of static lists of known functions.
-- A static spine is a Value clone whose body is a list of at most `spineMax` capture-free known functions (`oneOf [a, b, c]` after rule F).

-- the functions of a static spine
spineOf :: Info -> St -> MExpr -> Maybe [CloneId]
spineOf info st a =
  case mNode a of
    MGlobal g | Just d <- Map.lookup g (sDefs st), mdKind d == Value, Just b <- mdBody d, MList xs <- mNode b
              , length xs <= spineMax
              , Just fs <- mapM (\x -> case mNode x of { MGlobal l | Just _ <- staticCode info st l -> Just l; _ -> Nothing }) xs -> Just fs
    _ -> Nothing


-- the parameter `p` of `c` is only the scrutinee of `case p of [] -> ..; h :: t -> ..` (head and tail variables or wildcards), and the tail
-- is only passed at the same position to `c` itself
spineParam :: CloneId -> [String] -> String -> [MExpr] -> Bool
spineParam c ps p = all go
  where
    idx = List.elemIndex p ps
    go e = case mNode e of
      MCase s bs | MLocal x <- mNode s, x == p -> all okBranch bs && all (go . snd) bs
      MLocal x -> x /= p
      _ -> all go (children e)
    okBranch (pt, b) = case mpNode pt of
      PNil -> True
      PWild -> True
      PCons h t -> okH h && okT t b
      _ -> False
    okH h = case mpNode h of { PVar _ -> True; PWild -> True; _ -> False }
    okT t b = case mpNode t of { PWild -> True; PVar v -> tailUses v b; _ -> False }
    tailUses v e = case mNode e of
      MCall h as | MGlobal g <- mNode h, g == c -> and [ (Just i == idx && isV v a) || tailUses v a | (i, a) <- zip [0 :: Int ..] as ]
      MLocal x -> x /= v
      _ -> all (tailUses v) (children e)
    isV v x = case mNode x of { MLocal q -> q == v; _ -> False }


-- `case G of ..` with G a static spine: the branch that matches, with the head and tail variables replaced (the head by the function, the
-- tail by the static value of the rest of the list). Only the patterns that `spineParam` admits.
spineCase :: Info -> MExpr -> [(MPat, MExpr)] -> K (Maybe MExpr)
spineCase info s bs
  | not spineOn || not (all admitted bs) = return Nothing
  | otherwise =
  do  st <- get
      case (spineOf info st s, mNode s) of
        (Just fs, MGlobal g) ->
          case dropWhile (not . matches fs) bs of
            [] -> return Nothing
            ((pt, b) : _) ->
              do  bump "spine-reductions"
                  case (mpNode pt, fs) of
                    (PCons h t, f : _) ->
                      do  tl <- case mpNode t of { PVar v -> fmap (\a -> [(v, a)]) (tailValue g s); _ -> return [] }
                          let hs = case mpNode h of { PVar v -> [(v, MExpr (mpRep h) (MGlobal f))]; _ -> [] }
                          return (Just (substLocals (Map.fromList (hs ++ tl)) b))
                    _ -> return (Just b)
        _ -> return Nothing
  where
    admitted (pt, _) = case mpNode pt of
      PNil -> True
      PWild -> True
      PCons h t -> okAtom h && okAtom t
      _ -> False
    okAtom x = case mpNode x of { PVar _ -> True; PWild -> True; _ -> False }
    matches fs (pt, _) = case mpNode pt of { PNil -> null fs; PWild -> True; PCons _ _ -> not (null fs); _ -> False }


-- the static value of the tail of the static spine `g` (made once)
tailValue :: CloneId -> MExpr -> K MExpr
tailValue g s =
  do  st <- get
      case Map.lookup g (sTails st) of
        Just t -> return (MExpr (mRep s) (MGlobal t))
        Nothing ->
          case Map.lookup g (sDefs st) >>= mdBody of
            Just b | MList (_ : rest) <- mNode b ->
              do  (a, _) <- floatData (MExpr (mRep b) (MList rest))
                  case mNode a of
                    MGlobal t -> modify' (\s' -> s' { sTails = Map.insert g t (sTails s') })
                    _ -> return ()
                  bump "spine-tails"
                  return a
            _ -> return s


-- replace the free occurrences of the given locals by atoms (binders shadow)
substLocals :: Map.Map String MExpr -> MExpr -> MExpr
substLocals sub0 = go sub0
  where
    go sub e
      | Map.null sub = e
      | otherwise =
          case mNode e of
            MLocal n | Just a <- Map.lookup n sub -> a
            MLetVal n v b -> e { mNode = MLetVal n (go sub v) (go (Map.delete n sub) b) }
            MCase s bs -> e { mNode = MCase (go sub s) [ (p, go (foldr Map.delete sub (patVars p)) b) | (p, b) <- bs ] }
            MLam ps b -> e { mNode = MLam ps (go (foldr (Map.delete . fst) sub ps) b) }
            _ -> runIdentity (mapChildrenM (Identity . go sub) e)


-- a call whose head and arguments are rewritten
rwCall :: Info -> Env -> MExpr -> MExpr -> [MExpr] -> K MExpr
rwCall info env e h args =
  do  st <- get
      case mNode h of
        MGlobal c | expandOn, Just d <- Map.lookup c (sDefs st), mdKind d == Function, isJust (mdBody d) ->
          let n = length (mdParams d)
              m = length args
          in if m == n then exact c d
             else if m > n && n > 0
               then do { let { (first, rest) = splitAt n args }
                       ; inner <- exact' c d (e { mRep = mdResult d }) first
                       ; case mNode inner of
                           MCall ih _ | MGlobal c' <- mNode ih, c' == c -> return plain
                           _ -> do { bump "over-application-split"; return e { mNode = MCall inner rest } } }
               else return plain
        _ -> return plain
  where
    plain = e { mNode = MCall h args }
    exact c d = exact' c d e args
    exact' c d ex as =
      do  st <- get
          case Map.lookup c (sConstFn st) of
            Just code | all atomE as -> do { bump "const-calls"; return ex { mNode = MGlobal code } }
            _ | Set.member c (iBuilder info) ->
                  do  r <- tryExpand info env ex c d as
                      case r of
                        Just x -> return x
                        Nothing -> spec ex c d as
              | otherwise -> spec ex c d as
    spec ex c d as = fmap (fromMaybe ex { mNode = MCall h as }) (if specOn then trySpecialize info env ex h c d as else return Nothing)


-- EXPANSION

data Kind = KFun | KFunCap | KStatic | KFloat | KLocal | KDyn
  deriving (Eq, Show)


-- an argument of a builder call: its atom (a known local is replaced by its code) and what it is
classify :: Info -> Env -> MExpr -> K (MExpr, Kind)
classify info env a =
  do  st <- get
      let isStatic l = isJust (staticCode info st l)
          capFree l = null (Map.findWithDefault [] l (sCaps st))
          leaf x = case mNode x of
            MLit _ -> True
            MCtor _ _ _ -> True
            MGlobal l -> isStatic l
            MList xs -> all leaf xs
            MTuple xs -> all leaf xs
            MRecord fs -> all (leaf . snd) fs
            MCall hd xs | MCtor _ _ _ <- mNode hd -> all leaf xs
            _ -> False
      return $ case mNode a of
        MLit _ -> (a, KStatic)
        MCtor _ _ _ -> (a, KStatic)
        MLocal x | Just l <- Map.lookup x env -> (a { mNode = MGlobal l }, KFun)
                 | otherwise -> (a, KLocal)
        MGlobal l
          | Just t <- Map.lookup l (sAlias st) -> (a { mNode = MGlobal t }, KFun)
          | Just d <- Map.lookup l (sDefs st), mdKind d == Value -> (a, KStatic)
          | Just d <- Map.lookup l (sDefs st), mdKind d == Function ->
              if capFree l && isStatic l then (a, KFun) else if mdLifted d /= Nothing then (a, KFunCap) else (a, KDyn)
        MList _ | leaf a -> (a, KFloat)
        MTuple _ | leaf a -> (a, KFloat)
        MRecord _ | leaf a -> (a, KFloat)
        MCall hd _ | MCtor _ _ _ <- mNode hd, leaf a -> (a, KFloat)
        _ -> (a, KDyn)


-- every use of the variable in the bodies is the head of a call
headOnly :: String -> [MExpr] -> Bool
headOnly p = all go
  where
    go e = case mNode e of
      MCall h as -> (case mNode h of { MLocal x | x == p -> True; _ -> go h }) && all go as
      MLocal x -> x /= p
      _ -> all go (children e)


shapeKey :: MExpr -> String
shapeKey a = case mNode a of
  MLit l -> "L" ++ show l
  MGlobal (CloneId n) -> "G" ++ show n
  MCtor n t _ -> "C" ++ n ++ show t
  _ -> "?"


tryExpand :: Info -> Env -> MExpr -> CloneId -> MDef -> [MExpr] -> K (Maybe MExpr)
tryExpand info env e c d args =
  do  st0 <- get
      let origin = Map.findWithDefault c c (sOrigin st0)
          used = Map.findWithDefault 0 origin (sPerOrig st0)
      if Set.member c (iRec info) then refuse "recursive"
      else if c `elem` sStack st0 then refuse "on-stack"
      else do
        cl <- mapM (classify info env) args
        let defs = sDefs st0
            fam = family defs c
            bodies = [ b | x <- d : fam, Just b <- [mdBody x] ]
            ps = map fst (mdParams d)
            -- a known function with captures is substituted only where the body calls it (a use as a value would build a closure per use)
            demote (a, k) p | k == KFunCap && not (headOnly p bodies) = (a, KDyn)
                            | otherwise = (a, k)
            cl' = zipWith demote cl ps
            ks = map snd cl'
            known = any (`elem` [KFun, KFunCap]) ks
            allStatic = all (`elem` [KStatic, KFun, KFloat]) ks
            size = sum (map nodeCount bodies)
        if not (known || allStatic) then refuse "no-known-argument"
        else if used >= perOriginMax then refuse "per-origin-budget"
        else if size > budget then refuse "family-size"
        else if sAdded st0 + size > max programFloor (iSize info) then refuse "program-budget"
        else do
          let memoKey = (origin, map (shapeKey . fst) cl')
              pureStatic = all (`elem` [KStatic, KFun]) ks
          case (pureStatic, Map.lookup memoKey (sMemo st0)) of
            (True, Just r) -> do { bump "memo-hits"; return (Just r { mRep = mRep e }) }
            _ -> do
              -- floats, then lets for the arguments that are not atoms
              fl <- mapM (\(a, k) -> if k == KFloat then floatData a else return (a, k)) cl'
              suffix <- freshSuffix
              let step (lets, acc) ((a, k), (n, _)) =
                    if k == KDyn || not (atomE a)
                      then let nm = n ++ "@a" ++ show suffix in (lets ++ [(nm, a)], acc ++ [a { mNode = MLocal nm }])
                      else (lets, acc ++ [a])
                  (lets', atoms) = foldl step ([], []) (zip fl (mdParams d))
                  sub = Map.fromList (zip ps atoms)
              r <- copyFamily budget defs (sCaps st0) sub c (sCur st0)
              case r of
                Nothing -> return Nothing
                Just (_, body, copies) ->
                  do  bumpN size "nodes-added"
                      bump "expansions"
                      bump ("expand:" ++ mdName d)
                      registerCopies origin c size copies
                      modify' (\s -> s { sStack = c : sStack s })
                      mapM_ (rewriteClone info . mdClone) copies
                      body' <- rw info env body
                      modify' (\s -> s { sStack = drop 1 (sStack s) })
                      let result = foldr (\(nm, a) b -> MExpr (mRep e) (MLetVal nm a b)) body' lets'
                      when (null lets' && pureStatic && isMGlobal body') (modify' (\s -> s { sMemo = Map.insert memoKey body' (sMemo s) }))
                      return (Just result)
  where
    refuse why = do { bump ("refused-" ++ why); return Nothing }
    isMGlobal x = case mNode x of { MGlobal _ -> True; _ -> False }


-- the copies enter the program: definitions, origins, the budget counters and their captured variables
registerCopies :: CloneId -> CloneId -> Int -> [MDef] -> K ()
registerCopies origin _ size copies =
  modify' $ \s ->
    let defs' = List.foldl' (\m x -> Map.insert (mdClone x) x m) (sDefs s) copies
        origins = List.foldl' (\m x -> Map.insert (mdClone x) (fromMaybe origin (Map.lookup (mdClone x) m)) m) (sOrigin s) copies
    in s { sDefs = defs', sNew = reverse (map mdClone copies) ++ sNew s, sOrigin = origins
         , sPerOrig = Map.insertWith (+) origin 1 (sPerOrig s), sAdded = sAdded s + size
         , sCaps = newCaps (sCaps s) copies }


-- SPECIALIZATION (W3): a call of a function with known function arguments becomes a call of a copy in which they are substituted

-- the parameter is an argument or the head of a call in the bodies (so that knowing it can make a call direct or an expansion possible)
usefulParam :: String -> [MExpr] -> Bool
usefulParam p = any go
  where
    isP x = case mNode x of { MLocal q -> q == p; _ -> False }
    callable h = case mNode h of { MGlobal _ -> True; MLocal _ -> True; _ -> False }
    go e = (case mNode e of
              MCall h as | callable h -> any isP (h : as)
              _ -> False) || any go (children e)


-- every use of the parameter is the head of a call, or the argument at its own position of a recursive call of `c`
-- (a known function with captures is then not built again at a use)
headOrSelf :: CloneId -> [String] -> String -> [MExpr] -> Bool
headOrSelf c ps p = all go
  where
    idx = List.elemIndex p ps
    isP x = case mNode x of { MLocal q -> q == p; _ -> False }
    go e = case mNode e of
      MCall h as | MGlobal g <- mNode h, g == c -> and [ (Just i == idx && isP a) || go a | (i, a) <- zip [0 :: Int ..] as ]
      MCall h as -> (isP h || go h) && all go as
      MLocal x -> x /= p
      _ -> all go (children e)


trySpecialize :: Info -> Env -> MExpr -> MExpr -> CloneId -> MDef -> [MExpr] -> K (Maybe MExpr)
trySpecialize info env e h c d args
  | mdKind d /= Function || Just c == iMain info || null args = return Nothing
  | otherwise =
  do  st0 <- get
      cl <- mapM (classify info env) args
      let defs = sDefs st0
          fam = family defs c
          bodies = [ b | x <- d : fam, Just b <- [mdBody x] ]
          ps = map fst (mdParams d)
          pick (a, k) p
            | k == KFun && usefulParam p bodies = Just a
            | k == KFunCap && usefulParam p bodies && headOrSelf c ps p bodies = Just a
            | k == KStatic, spineOn, null fam, Just _ <- spineOf info st0 a, spineParam c ps p bodies = Just a
            | otherwise = Nothing
          picks = zipWith pick cl ps
          origin = Map.findWithDefault c c (sOrigin st0)
          used = Map.findWithDefault 0 origin (sPerOrig st0)
          size = sum (map nodeCount bodies)
          shape = maybe "_" (\a -> case mNode a of { MGlobal (CloneId n) -> "F" ++ show n; _ -> "?" })
          key = (c, map shape picks)
          extras = List.nubBy (\x y -> fst x == fst y)
                     [ nc | Just a <- picks, MGlobal l <- [mNode a], nc <- Map.findWithDefault [] l (sCaps st0) ]
          isSpine = or [ True | Just a <- picks, Just _ <- [spineOf info st0 a] ]
          spineUsed = Map.findWithDefault 0 origin (sSpineN st0)
          dyn = [ a | (a, Nothing) <- zip args picks ]
          callOf sid ex = e { mNode = MCall (h { mNode = MGlobal sid }) (dyn ++ [ MExpr cls (MLocal n) | (n, cls) <- ex ]) }
      if all (== Nothing) (map (fmap (const ())) picks) then return Nothing
      else case Map.lookup key (sSpec st0) of
        Just (sid, ex) -> do { bump "spec-memo-hits"; return (Just (callOf sid ex)) }
        Nothing
          | isSpine && spineUsed >= spinePerOriginMax -> refuse "spine-per-origin-budget"
          | not isSpine && used >= perOriginMax -> refuse "spec-per-origin-budget"
          | size > specBudget -> refuse "spec-family-size"
          | sAdded st0 + size > max programFloor (iSize info) -> refuse "spec-program-budget"
          | otherwise ->
              do  sid <- freshId
                  let sub = Map.fromList [ (p, a) | (p, Just a) <- zip ps picks ]
                  r <- copyFamily specBudget defs (sCaps st0) sub c sid
                  case r of
                    Nothing -> return Nothing
                    Just (remaining, body, copies) ->
                      do  let nd = d { mdClone = sid, mdParams = remaining ++ extras, mdBody = Just body
                                     , mdLifted = fmap (const (sCur st0)) (mdLifted d)
                                     , mdOwn = [], mdTwin = Nothing, mdCapsOwned = False, mdInit = Nothing, mdNeeds = [] }
                          bumpN size "nodes-added"
                          bump "specializations"
                          when isSpine (do { bump "spine-specializations"; modify' (\s -> s { sSpineN = Map.insertWith (+) origin 1 (sSpineN s) }) })
                          bump ("specialize:" ++ mdName d)
                          registerCopies origin c size (nd : copies)
                          modify' (\s -> s { sSpec = Map.insert key (sid, extras) (sSpec s) })
                          mapM_ (rewriteClone info . mdClone) copies
                          rewriteClone info sid
                          return (Just (callOf sid extras))
  where
    refuse why = do { bump ("refused-" ++ why); return Nothing }


-- the captured variables of new clones (the rule of Free.captures: names used and not bound, plus those of the lifted clones called),
-- given the table of the old clones
newCaps :: Map.Map CloneId [(String, Class)] -> [MDef] -> Map.Map CloneId [(String, Class)]
newCaps old news = Map.union (fixp start) old
  where
    byId = Map.fromList [ (mdClone x, x) | x <- news ]
    own x = let (_, bound) = maybe (Map.empty, Set.empty) usedBound (mdBody x) in Set.union bound (Set.fromList (map fst (mdParams x)))
    direct x = maybe Map.empty (\b -> Map.filterWithKey (\k _ -> not (Set.member k (own x))) (fst (usedBound b))) (mdBody x)
    start = Map.fromList [ (mdClone x, if mdLifted x == Nothing then Map.empty else direct x) | x <- news ]
    lookupC m r = case Map.lookup r m of
      Just v -> v
      Nothing -> Map.fromList (Map.findWithDefault [] r old)
    fixp m =
      let step = Map.mapWithKey (\c cur ->
                   case Map.lookup c byId of
                     Nothing -> cur
                     Just x -> Map.union cur (Map.unions [ Map.filterWithKey (\k _ -> not (Set.member k (own x))) (lookupC m r)
                                                          | r <- maybe [] exprRefs (mdBody x), r /= c ])) m
      in if step == m then Map.map Map.toList m else fixp step


usedBound :: MExpr -> (Map.Map String Class, Set.Set String)
usedBound e =
  let here = case mNode e of
        MLocal n -> (Map.singleton n (mRep e), Set.empty)
        MLetVal n _ _ -> (Map.empty, Set.singleton n)
        MCase _ bs -> (Map.empty, Set.fromList (concatMap (patVars . fst) bs))
        _ -> (Map.empty, Set.empty)
      below = map usedBound (children e)
  in (Map.unions (fst here : map fst below), Set.unions (snd here : map snd below))


-- RULE F: a closed data literal becomes a global value (a capture-free function leaf needs no initialisation order)
floatData :: MExpr -> K (MExpr, Kind)
floatData a =
  do  cid <- freshId
      let d = MDef { mdClone = cid, mdName = "known$float", mdKey = Key [], mdKind = Value, mdParams = [], mdResult = mRep a, mdBody = Just a
                   , mdInit = Nothing, mdNeeds = [], mdLifted = Nothing, mdVars = [], mdOwn = [], mdTwin = Nothing, mdCapsOwned = False }
      modify' (\s -> s { sFloated = d : sFloated s, sDefs = Map.insert cid d (sDefs s) })
      bump "floated"
      return (a { mNode = MGlobal cid }, KStatic)


mapChildrenM :: Monad m => (MExpr -> m MExpr) -> MExpr -> m MExpr
mapChildrenM f e =
  do  node <- case mNode e of
        MLit _ -> same
        MLocal _ -> same
        MGlobal _ -> same
        MKernel _ _ -> same
        MCtor _ _ _ -> same
        MCall h as -> MCall <$> f h <*> mapM f as
        MLam ps b -> MLam ps <$> f b
        MIf bs el -> MIf <$> mapM (\(c, b) -> (,) <$> f c <*> f b) bs <*> f el
        MLetVal n v b -> MLetVal n <$> f v <*> f b
        MSeq a b -> MSeq <$> f a <*> f b
        MCase s bs -> MCase <$> f s <*> mapM (\(p, b) -> (,) p <$> f b) bs
        MAccess x n i -> (\x' -> MAccess x' n i) <$> f x
        MUpdate x fs -> MUpdate <$> f x <*> mapM (\(n, v) -> (,) n <$> f v) fs
        MRecord fs -> MRecord <$> mapM (\(n, v) -> (,) n <$> f v) fs
        MTuple xs -> MTuple <$> mapM f xs
        MList xs -> MList <$> mapM f xs
        MDup vs x -> MDup vs <$> f x
        MDrop vs x -> MDrop vs <$> f x
        MUnpack a c ps x -> MUnpack a c ps <$> f x
        MSpec a cs ps t x -> MSpec a cs ps t <$> f x
        MReuse t x -> MReuse t <$> f x
        MFreeTok t x -> MFreeTok t <$> f x
        MOwn x -> MOwn <$> f x
      return e { mNode = node }
  where same = return (mNode e)


-- THE SCOPE CHECKER (invariant S)

-- | wherever a lifted clone is referenced, every variable it captures is bound there (a parameter of the clone, one of its own captured
-- variables, or a let or pattern variable on the path)
checkScope :: [MDef] -> [String]
checkScope clones =
  [ msg | d <- clones, Just b <- [mdBody d]
        , msg <- walk d (Set.fromList (map fst (mdParams d) ++ map fst (Map.findWithDefault [] (mdClone d) caps))) b ]
  where
    caps = captures clones
    walk d bound e =
      case mNode e of
        MGlobal l
          | Just ls <- Map.lookup l caps, missing@(_ : _) <- [ n | (n, _) <- ls, not (Set.member n bound) ] ->
              [ "known check: c" ++ show (cid (mdClone d)) ++ " " ++ mdName d ++ " refers to c" ++ show (cid l)
                ++ " but does not bind its captured variable(s) " ++ unwords missing ]
        MLetVal n v b -> walk d bound v ++ walk d (Set.insert n bound) b
        MCase s bs -> walk d bound s ++ concat [ walk d (foldr Set.insert bound (patVars p)) b | (p, b) <- bs ]
        MLam ps b -> walk d (foldr (Set.insert . fst) bound ps) b
        _ -> concatMap (walk d bound) (children e)
    cid (CloneId n) = n


-- | closedness (H16 W3 fix): the checks that `checkScope` cannot make because it counts the variables that a clone inherits from the lifted
-- clones it refers to as bound.
--   1. a top level clone (not lifted) has no captured variable, direct or inherited: its body is closed over globals;
--   2. a lifted clone captures only what its owner has in scope (a parameter, a binder of the owner's body, or a captured variable of the owner);
--   3. what the worker runtime calls by name (the clones `main` refers to) has no captured variable;
--   4. no clone that existed before the pass has another parameter list (new clones are free to choose theirs): `fic_main` and the closure
--      runtime call by the old signature.
checkClosed :: Maybe CloneId -> [MDef] -> [MDef] -> [String]
checkClosed mainId before after =
  [ top d | d <- after, mdLifted d == Nothing, isJust (mdBody d), not (null (names (mdClone d))) ]
  ++ [ own d o missing | d <- after, Just o <- [mdLifted d], Just od <- [Map.lookup o byId]
                       , let scope = Set.unions [ Set.fromList (map fst (mdParams od)), Set.fromList (maybe [] binders (mdBody od)), Set.fromList (names o) ]
                       , let missing = [ n | n <- names (mdClone d), not (Set.member n scope) ], not (null missing) ]
  ++ [ "closed check: entry point c" ++ show (cid c) ++ " " ++ maybe "?" mdName (Map.lookup c byId) ++ " (referenced by main) has captured variable(s) " ++ unwords (names c)
     | Just m <- [mainId], Just md <- [Map.lookup m byId], Just mb <- [mdBody md], c <- exprRefs mb, c /= m, not (null (names c)) ]
  ++ [ "closed check: c" ++ show (cid (mdClone d)) ++ " " ++ mdName d ++ " changed its parameters from " ++ show (map fst (mdParams o)) ++ " to " ++ show (map fst (mdParams d))
     | d <- after, Just o <- [Map.lookup (mdClone d) beforeById], map fst (mdParams o) /= map fst (mdParams d) ]
  where
    caps = captures after
    byId = Map.fromList [ (mdClone d, d) | d <- after ]
    beforeById = Map.fromList [ (mdClone d, d) | d <- before ]
    names c = map fst (Map.findWithDefault [] c caps)
    cid (CloneId n) = n
    top d = "closed check: top level c" ++ show (cid (mdClone d)) ++ " " ++ mdName d ++ " has free variable(s) " ++ unwords (names (mdClone d))
               ++ " (through " ++ unwords [ "c" ++ show (cid r) | r <- maybe [] exprRefs (mdBody d), not (null (names r)) ] ++ ")"
    own d o missing = "closed check: c" ++ show (cid (mdClone d)) ++ " " ++ mdName d ++ " (lifted from c" ++ show (cid o) ++ ") captures " ++ unwords missing ++ ", which its owner does not bind"


-- THE COPY KIT

-- | the lifted clones that belong to the family of `root`: referenced from its body (or from another member) and lifted out of it, directly
-- or through other members
family :: Map.Map CloneId MDef -> CloneId -> [MDef]
family byId root = go Set.empty (refsOf root) []
  where
    refsOf c = maybe [] (maybe [] exprRefs . mdBody) (Map.lookup c byId)
    inFam d = leads (20 :: Int) (mdLifted d)
    leads n (Just o) | o == root = True
                     | n > 0 = maybe False (leads (n - 1) . mdLifted) (Map.lookup o byId)
    leads _ _ = False
    go _ [] acc = reverse acc
    go seen (c : cs) acc
      | c == root || Set.member c seen = go seen cs acc
      | Just d <- Map.lookup c byId, inFam d = go (Set.insert c seen) (cs ++ refsOf c) (d : acc)
      | otherwise = go (Set.insert c seen) cs acc


binders :: MExpr -> [String]
binders e =
  (case mNode e of
     MLetVal n _ _ -> [n]
     MCase _ bs -> concatMap (patVars . fst) bs
     MLam ps _ -> map fst ps
     _ -> []) ++ concatMap binders (children e)


nodeCount :: MExpr -> Int
nodeCount e = 1 + sum (map nodeCount (children e))


-- | Copy the body of `root` together with its family under one renaming: every binder (parameter, let, pattern, lambda parameter) of the
-- family gets the suffix "@k<n>" (by name: one renaming for the family; a name that clashes with a captured variable of the root makes the copy refused: Nothing), every parameter of `root`
-- named in the substitution is replaced by its atom (the class of the atom must be the class of the parameter), every lifted clone of the
-- family is copied to a fresh clone id and every reference to it is remapped. Result: the parameters of `root` that are not substituted
-- (renamed), the copied body, the copied family (owner `newOwner` for the clones that were lifted out of `root`; `mdOwn`, `mdTwin`,
-- `mdCapsOwned`, `mdInit`, `mdNeeds` reset). Free names that are neither binders of the family nor substituted are left alone.
copyFamily :: Int -> Map.Map CloneId MDef -> Map.Map CloneId [(String, Class)] -> Map.Map String MExpr -> CloneId -> CloneId
           -> K (Maybe ([(String, Class)], MExpr, [MDef]))
copyFamily limit byId caps sub root newOwner =
  case Map.lookup root byId of
    Just d | Just body <- mdBody d ->
      let fam = family byId root
          defs = d : fam
          bodies = [ b | x <- defs, Just b <- [mdBody x] ]
          names = concat [ map fst (mdParams x) ++ maybe [] binders (mdBody x) | x <- defs ]
          -- a captured variable of the root that is also a binder name of the family cannot be told apart from it in a lifted child
          -- (captured names are matched by name), so such a family is refused
          clash = not (null fam) && any (\(n, _) -> n `elem` names) (Map.findWithDefault [] root caps)
          -- a substituted parameter that is bound again somewhere in the family: scope aware renaming handles it in the root body, but a
          -- lifted child that uses the name free would be ambiguous
          subClash = not (null fam) && any (\n -> Map.member n sub && n `elem` concatMap (maybe [] binders . mdBody) defs) (map fst (mdParams d))
          classOk = and [ maybe True (\a -> mRep a == c) (Map.lookup n sub) | (n, c) <- mdParams d ]
          size = sum (map nodeCount bodies)
          -- H16 W3 fix: a lifted clone that the copy refers to but that is not part of the family (its owner is another clone) finds its captured
          -- variables by name in the scope of the call. If one of those names is a parameter or binder that the copy renames or replaces (the
          -- extra parameter of an earlier specialization, say), the copy would leave the name free: refuse
          outsideCaptures = not (null [ () | r <- concatMap exprRefs bodies, r /= root, r `notElem` map mdClone fam
                                           , (n, _) <- Map.findWithDefault [] r caps, n `elem` names ])
      in if outsideCaptures then do { bump "copy-refused-outside-capture"; return Nothing }
         else if clash || subClash then do { bump "copy-refused-capture-clash"; return Nothing }
         else if not classOk then do { bump "copy-refused-shape"; return Nothing }
         else if size > limit then do { bump "copy-refused-budget"; return Nothing }
         else
           do  k <- freshSuffix
               ids <- mapM (const freshId) fam
               let idm = Map.fromList (zip (map mdClone fam) ids)
                   rn n = n ++ "@k" ++ show k
                   -- the names a body starts with: its own parameters (renamed), the parameters of the root (substituted or renamed) and
                   -- every binder name of the family (a lifted child uses the names of its owner free: one renaming by name)
                   base x = Map.unions [ Map.fromList [ (n, BRen) | mdClone x /= root, (n, _) <- mdParams x ]
                                       , Map.fromList [ (n, maybe BRen BSub (Map.lookup n sub)) | (n, _) <- mdParams d ]
                                       , Map.fromList [ (n, BRen) | n <- names ] ]
                   cp x = copyExpr (base x) rn idm
                   params x = [ (rn n, c) | (n, c) <- mdParams x ]
                   owner o = if o == root then newOwner else Map.findWithDefault newOwner o idm
                   copyDef x c =
                     x { mdClone = c, mdParams = params x, mdBody = fmap (cp x) (mdBody x), mdLifted = fmap owner (mdLifted x)
                       , mdOwn = [], mdTwin = Nothing, mdCapsOwned = False, mdInit = Nothing, mdNeeds = [] }
               bump "copies"
               return (Just ([ (rn n, c) | (n, c) <- mdParams d, not (Map.member n sub) ], cp d body, zipWith copyDef fam ids))
    _ -> return Nothing


data Bind = BRen | BSub MExpr


-- | the scope aware copy: `env` says what a name means at this point (renamed, or replaced by an atom); a name that is not in it is free
-- and stays. A binder shadows the entry of its name (a renamed binder is `BRen`, so a substituted parameter that is bound again is not
-- replaced inside the scope of the new binder).
copyExpr :: Map.Map String Bind -> (String -> String) -> Map.Map CloneId CloneId -> MExpr -> MExpr
copyExpr env0 rn idm = go env0
  where
    bind ns env = foldr (\n -> Map.insert n BRen) env ns
    go env e =
      case mNode e of
        MLocal n -> case Map.lookup n env of
                      Just (BSub a) -> a
                      Just BRen -> e { mNode = MLocal (rn n) }
                      Nothing -> e
        MGlobal c | Just c' <- Map.lookup c idm -> e { mNode = MGlobal c' }
        MLam ps b -> e { mNode = MLam [ (rn n, c) | (n, c) <- ps ] (go (bind (map fst ps) env) b) }
        MLetVal n v b -> e { mNode = MLetVal (rn n) (go env v) (go (bind [n] env) b) }
        MCase s bs -> e { mNode = MCase (go env s) [ (pat p, go (bind (patVars p) env) b) | (p, b) <- bs ] }
        _ -> runIdentity (mapChildrenM (Identity . go env) e)
    pat p = p { mpNode = case mpNode p of
                  PVar v -> PVar (rn v)
                  PCtor n t ps -> PCtor n t (map pat ps)
                  PTuple ps -> PTuple (map pat ps)
                  PCons a b -> PCons (pat a) (pat b)
                  PAlias q v -> PAlias (pat q) (rn v)
                  PRecord fs -> PRecord [ (i, rn v, c) | (i, v, c) <- fs ]
                  other -> other }


-- the self test: copy the family of every function clone that has one (unused), put the copies next to the originals and check scope
copyTest :: Map.Map CloneId MDef -> Map.Map CloneId [(String, Class)] -> [MDef] -> K [String]
copyTest byId caps clones =
  do  let targets = [ d | d <- clones, mdKind d == Function, isJust (mdBody d), not (null (family byId (mdClone d))) ]
      copies <- mapM one targets
      let made = concat [ r | Just r <- copies ]
      bumpN (length [ () | Just _ <- copies ]) "copytest-ok"
      bumpN (length [ () | Nothing <- copies ]) "copytest-refused"
      mapM_ (\(d, r) -> bump ((if isJust r then "family-ok:" else "family-refused:") ++ mdName d)) (zip targets copies)
      return (checkScope (clones ++ made))
  where
    one d =
      do  newId <- freshId
          r <- copyFamily budget byId caps Map.empty (mdClone d) newId
          return (fmap (\(ps, b, fam) -> d { mdClone = newId, mdParams = ps, mdBody = Just b } : fam) r)
