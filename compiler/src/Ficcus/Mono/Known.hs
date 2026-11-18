{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE PatternGuards #-}
module Ficcus.Mono.Known
  ( knownProgram
  , knownRun
  , checkScope
  )
  where


-- Ficcus, H16 stage 1 (docs/H16-DESIGN.md): known function specialization, work item W1.
--
-- A Mono -> Mono pass that runs before Inline, only with --rc. W1 has: the switches and counters, the copy kit (a function copied together
-- with its lifted children under one consistent renaming), the scope checker (invariant S: wherever a lifted clone is referenced, the
-- variables it captures are bound), rule V (a top level value whose body is a capture-free closure is an alias of that closure: calls of
-- it become direct calls, value uses become the static closure), and direct calls through let-bound capture-free closures.
--
-- Switches (environment): FICCUS_NO_KNOWN=1 returns the program unchanged; FICCUS_KNOWN_STATS=1 (read by Make.hs) prints the counters;
-- FICCUS_KNOWN_CHECK=1 runs the scope checker on the result and fails the compile on a violation; FICCUS_KNOWN_BUDGET=n is the largest family
-- (node count) that the copy kit copies (default 200); FICCUS_KNOWN_COPYTEST=1 copies every function family once, unused, and checks the
-- copies (a self test of the copy kit).


import Control.Monad.State.Strict (State, get, modify', put, runState)
import qualified Data.Map.Strict as Map
import Data.Functor.Identity (Identity(..))
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

{-# NOINLINE budget #-}
budget :: Int
budget = unsafePerformIO (fmap (fromMaybe 200 . (>>= readMaybe)) (lookupEnv "FICCUS_KNOWN_BUDGET"))


data St = St
  { sSuffix :: Int                       -- the copy number: names of a copy end in "@k<n>"
  , sNext :: Int                         -- the next free clone id
  , sStats :: Map.Map String Int
  }

type K = State St


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


-- | the pass and its counters (empty when the pass is off)
knownRun :: MProgram -> (Either [String] MProgram, [(String, Int)])
knownRun prog
  | not knownOn = (Right prog, [])
  | otherwise = (if null errs then Right prog { mpClones = kept } else Left errs, Map.toList (sStats st))
  where
    clones = mpClones prog
    byId = Map.fromList [ (mdClone d, d) | d <- clones ]
    caps = captures clones
    aliases = aliasMap byId caps (mpMain prog)
    ctx = Ctx aliases byId caps
    start = St 0 (1 + maximum (0 : [ n | d <- clones, let CloneId n = mdClone d ])) Map.empty
    ((kept, testErrs), st) = runState go start
    go =
      do  bumpN (Map.size aliases) "aliases"
          rewritten <- mapM (rewriteDef ctx) clones
          let referenced = Set.fromList (concat [ exprRefs b | d <- rewritten, Just b <- [mdBody d] ] ++ concatMap mdNeeds rewritten ++ maybe [] pure (mpMain prog))
              dead d = Map.member (mdClone d) aliases && not (Set.member (mdClone d) referenced)
              kept' = filter (not . dead) rewritten
          bumpN (length rewritten - length kept') "aliases-removed"
          terrs <- if copyTestOn then copyTest byId kept' else return []
          return (kept', terrs)
    errs = testErrs ++ (if checkOn then checkScope kept else [])


-- RULE V

data Ctx = Ctx
  { cAlias :: Map.Map CloneId CloneId                 -- Value clone -> the capture-free Function clone it is an alias of
  , cDefs :: Map.Map CloneId MDef
  , cCaps :: Map.Map CloneId [(String, Class)]
  }


-- a Function clone with a body that has no captured variable: a call of it needs no scope, a use of it is the static closure
staticFn :: Map.Map CloneId MDef -> Map.Map CloneId [(String, Class)] -> Maybe CloneId -> CloneId -> Bool
staticFn byId caps root c =
  case Map.lookup c byId of
    Just d -> mdKind d == Function && isJust (mdBody d) && Just c /= root && null (Map.findWithDefault [] c caps)
    Nothing -> False


-- Value clones whose body is `MGlobal l` with l a capture-free Function clone (or an alias of one, a chain of at most 20 values)
aliasMap :: Map.Map CloneId MDef -> Map.Map CloneId [(String, Class)] -> Maybe CloneId -> Map.Map CloneId CloneId
aliasMap byId caps root =
  Map.fromList [ (v, t) | (v, t0) <- Map.toList direct, Just t <- [resolve (20 :: Int) t0], staticFn byId caps root t ]
  where
    direct = Map.fromList [ (mdClone d, t) | d <- Map.elems byId, mdKind d == Value, Just b <- [mdBody d], MGlobal t <- [mNode b], Just _ <- [Map.lookup t byId] ]
    resolve n t
      | Map.member t direct = if n > 0 then resolve (n - 1) (direct Map.! t) else Nothing
      | otherwise = Just t


rewriteDef :: Ctx -> MDef -> K MDef
rewriteDef ctx d =
  case mdBody d of
    Nothing -> return d
    Just b -> do { b' <- rw ctx Map.empty b; return d { mdBody = Just b' } }


-- env: the local variables bound to a capture-free closure
rw :: Ctx -> Map.Map String CloneId -> MExpr -> K MExpr
rw ctx env e =
  case mNode e of
    MCall h args ->
      do  args' <- mapM (rw ctx env) args
          h' <- case mNode h of
                  MGlobal v | Just l <- Map.lookup v (cAlias ctx) -> do { bump "direct-calls-alias"; return h { mNode = MGlobal l } }
                  MLocal x | Just l <- Map.lookup x env -> do { bump "direct-calls-let"; return h { mNode = MGlobal l } }
                  _ -> rw ctx env h
          return e { mNode = MCall h' args' }
    MGlobal v | Just l <- Map.lookup v (cAlias ctx) -> do { bump "value-uses"; return e { mNode = MGlobal l } }
    MLetVal n v b ->
      do  v' <- rw ctx env v
          let known = case mNode v' of
                MGlobal l | staticFn (cDefs ctx) (cCaps ctx) Nothing l -> Just l
                _ -> Nothing
              env' = maybe (Map.delete n env) (\l -> Map.insert n l env) known
          b' <- rw ctx env' b
          return e { mNode = MLetVal n v' b' }
    MCase s bs ->
      do  s' <- rw ctx env s
          bs' <- mapM (\(p, b) -> do { b' <- rw ctx (foldr Map.delete env (patVars p)) b; return (p, b') }) bs
          return e { mNode = MCase s' bs' }
    MLam ps b -> do { b' <- rw ctx (foldr (Map.delete . fst) env ps) b; return e { mNode = MLam ps b' } }
    _ -> mapChildrenM (rw ctx env) e


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


hasRecordPat :: MExpr -> Bool
hasRecordPat e =
  (case mNode e of { MCase _ bs -> any (recPat . fst) bs; _ -> False }) || any hasRecordPat (children e)
  where
    recPat p = case mpNode p of
      PRecord _ -> True
      PCtor _ _ ps -> any recPat ps
      PTuple ps -> any recPat ps
      PCons a b -> recPat a || recPat b
      PAlias q _ -> recPat q
      _ -> False


nodeCount :: MExpr -> Int
nodeCount e = 1 + sum (map nodeCount (children e))


-- | Copy the body of `root` together with its family under one renaming: every binder (parameter, let, pattern, lambda parameter) of the
-- family gets the suffix "@k<n>" (a binder name of the family must be unique, or the copy is refused: Nothing), every parameter of `root`
-- named in the substitution is replaced by its atom (the class of the atom must be the class of the parameter), every lifted clone of the
-- family is copied to a fresh clone id and every reference to it is remapped. Result: the parameters of `root` that are not substituted
-- (renamed), the copied body, the copied family (owner `newOwner` for the clones that were lifted out of `root`; `mdOwn`, `mdTwin`,
-- `mdCapsOwned`, `mdInit`, `mdNeeds` reset). Free names that are neither binders of the family nor substituted are left alone.
copyFamily :: Map.Map CloneId MDef -> Map.Map String MExpr -> CloneId -> CloneId -> K (Maybe ([(String, Class)], MExpr, [MDef]))
copyFamily byId sub root newOwner =
  case Map.lookup root byId of
    Just d | Just body <- mdBody d ->
      let fam = family byId root
          defs = d : fam
          bodies = [ b | x <- defs, Just b <- [mdBody x] ]
          names = concat [ map fst (mdParams x) ++ maybe [] binders (mdBody x) | x <- defs ]
          unique = Set.size (Set.fromList names) == length names
          classOk = and [ maybe True (\a -> mRep a == c) (Map.lookup n sub) | (n, c) <- mdParams d ]
          size = sum (map nodeCount bodies)
      in if not unique || any hasRecordPat bodies || not classOk then do { bump "copy-refused-shape"; return Nothing }
         else if size > budget then do { bump "copy-refused-budget"; return Nothing }
         else
           do  k <- freshSuffix
               ids <- mapM (const freshId) fam
               let idm = Map.fromList (zip (map mdClone fam) ids)
                   bset = Set.fromList names
                   rn n = n ++ "@k" ++ show k
                   cp = copyExpr (\n -> Map.lookup n sub) bset rn idm
                   params x = [ (rn n, c) | (n, c) <- mdParams x ]
                   owner o = if o == root then newOwner else Map.findWithDefault newOwner o idm
                   copyDef x c =
                     x { mdClone = c, mdParams = params x, mdBody = fmap cp (mdBody x), mdLifted = fmap owner (mdLifted x)
                       , mdOwn = [], mdTwin = Nothing, mdCapsOwned = False, mdInit = Nothing, mdNeeds = [] }
               bump "copies"
               return (Just ([ (rn n, c) | (n, c) <- mdParams d, not (Map.member n sub) ], cp body, zipWith copyDef fam ids))
    _ -> return Nothing


copyExpr :: (String -> Maybe MExpr) -> Set.Set String -> (String -> String) -> Map.Map CloneId CloneId -> MExpr -> MExpr
copyExpr sub bset rn idm = go
  where
    go e =
      case mNode e of
        MLocal n | Just a <- sub n -> a
                 | Set.member n bset -> e { mNode = MLocal (rn n) }
        MGlobal c | Just c' <- Map.lookup c idm -> e { mNode = MGlobal c' }
        MLam ps b -> e { mNode = MLam [ (rn n, c) | (n, c) <- ps ] (go b) }
        MLetVal n v b -> e { mNode = MLetVal (rn n) (go v) (go b) }
        MCase s bs -> e { mNode = MCase (go s) [ (pat p, go b) | (p, b) <- bs ] }
        _ -> runIdentity (mapChildrenM (Identity . go) e)
    pat p = p { mpNode = case mpNode p of
                  PVar v -> PVar (rn v)
                  PCtor n t ps -> PCtor n t (map pat ps)
                  PTuple ps -> PTuple (map pat ps)
                  PCons a b -> PCons (pat a) (pat b)
                  PAlias q v -> PAlias (pat q) (rn v)
                  other -> other }


-- the self test: copy the family of every function clone that has one (unused), put the copies next to the originals and check scope
copyTest :: Map.Map CloneId MDef -> [MDef] -> K [String]
copyTest byId clones =
  do  copies <- mapM one [ d | d <- clones, mdKind d == Function, isJust (mdBody d), not (null (family byId (mdClone d))) ]
      let made = concat [ r | Just r <- copies ]
      bumpN (length [ () | Just _ <- copies ]) "copytest-ok"
      bumpN (length [ () | Nothing <- copies ]) "copytest-refused"
      return (checkScope (clones ++ made))
  where
    one d =
      do  newId <- freshId
          r <- copyFamily byId Map.empty (mdClone d) newId
          return (fmap (\(ps, b, fam) -> d { mdClone = newId, mdParams = ps, mdBody = Just b } : fam) r)
