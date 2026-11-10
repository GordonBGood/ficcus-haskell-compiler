{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE PatternGuards #-}
module Ficcus.Mono.Rc
  ( rcProgram
  , rcMutate
  )
  where


-- Ficcus, stage (iv) slice S2: the Rc pass (docs/STAGE4-PLAN.md, section 3). Mono to Mono: it adds `MDup`, `MDrop` and `MOwn`
-- so that every reference is counted exactly once, Perceus style, with these conventions (v0: every parameter is owned):
--
--   * every expression yields an OWNED value: its consumer must consume the count (store it, pass it to an owned parameter,
--     return it, or drop it);
--   * an owned local variable is consumed by its last use (a "move", no instruction) and `dup`'d by every earlier use;
--   * a variable that is dead is dropped as early as possible: at the entry of the first expression that does not use it,
--     which is the start of a branch when it is dead only in that branch (this is what makes the result garbage free);
--   * a struct variable holds one count on each reference component and is dup'd and dropped as a whole (components are not
--     tracked separately yet);
--   * a pattern variable is a view into the scrutinee: when the branch uses it, it is dup'd at the start of the branch (so it is
--     owned like any other variable) and the scrutinee is dropped there when it is dead;
--   * kernel arguments are consumed (`o`) or borrowed (`b`) by the signature table (Ficcus.Mono.Kernel); a borrowed argument that is
--     not a variable is bound to a temporary that is dropped after the call, and an owned variable whose last use is a borrowed
--     argument is dropped after the call;
--   * the captured variables of a lifted function are passed by the caller and stay borrowed in the callee; a closure object takes
--     a count on each captured reference;
--   * `MOwn e` is for an expression that only *looks at* something that stays alive (a static object, a global value, a field of a
--     struct, an element of an array): it adds the count.
--
-- Evaluation order is the one the C generator uses (arguments left to right, `let` in order, `&&` and `||` lazy: they are
-- rewritten to `if` here, so that the pass sees that the second operand is conditional).
-- The independent checker of the result is Ficcus.Mono.RcCheck.


import Control.Monad (foldM)
import Control.Monad.State.Strict (State, evalState, get, gets, modify', put, runState)
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import Ficcus.Mono.Class
import Ficcus.Mono.Free
import Ficcus.Mono.Ir
import Ficcus.Mono.Kernel (kernelResultBorrowed, kernelSig)


type Env = Map.Map String Class          -- the owned variables of a reference class that are in scope
type Live = Set.Set String               -- the variables the rest of the computation (after the expression) uses


data RS =
  RS
    { rsN :: Int
    , rsErrors :: [String]
    , rsWhere :: String
    }


type RM a = State RS a


data Ctx =
  Ctx
    { cClones :: Map.Map CloneId MDef
    , cCaps :: Map.Map CloneId [(String, Class)]
    }


-- | the program with counts; the root (`main = Platform.worker ...`) is left alone
rcProgram :: MProgram -> Either [String] MProgram
rcProgram program =
  let clones = mpClones program
      ctx = Ctx (Map.fromList [ (mdClone d, d) | d <- clones ]) (captures clones)
      (clones', errs) = evalState (do { cs <- mapM (rcDef ctx (mpMain program)) clones; es <- gets rsErrors; return (cs, es) }) (RS 0 [] "")
  in if null errs then Right program { mpClones = clones' } else Left (reverse errs)


rcDef :: Ctx -> Maybe CloneId -> MDef -> RM MDef
rcDef ctx root d =
  case mdBody d of
    Just body | Just (mdClone d) /= root ->
      do  modify' (\s -> s { rsWhere = mdName d })
          let env = Map.fromList [ (n, c) | (n, c) <- mdParams d, refClass c ]
          body' <- rc ctx env Set.empty body
          return d { mdBody = Just body' }
    _ -> return d


failRc :: String -> RM ()
failRc msg =
  modify' (\s -> s { rsErrors = (msg ++ " (in " ++ rsWhere s ++ ")") : rsErrors s })


fresh :: RM String
fresh =
  do  n <- gets rsN
      modify' (\s -> s { rsN = n + 1 })
      return ("rc_" ++ show n)


fvOf :: Ctx -> MExpr -> Map.Map String Class
fvOf ctx = freeVars (cCaps ctx)


fvNames :: Ctx -> MExpr -> Set.Set String
fvNames ctx = Map.keysSet . fvOf ctx


-- | the expression, consuming every owned variable of `env` that is not in `live` (and using `live` without consuming it):
-- the variables of `env` that the expression does not use and `live` does not need are dropped first
rc :: Ctx -> Env -> Live -> MExpr -> RM MExpr
rc ctx env live e =
  do  let fvE = fvOf ctx e
      let dead = [ (n, c) | (n, c) <- Map.toList env, not (Map.member n fvE), not (Set.member n live) ]
      let env' = foldr (Map.delete . fst) env dead
      e' <- rcNode ctx env' live e
      return (if null dead then e' else MExpr (mRep e) (MDrop dead e'))


-- | the owned variables that are still owned after something that needed `live`
consumedAfter :: Env -> Live -> Env
consumedAfter env live = Map.filterWithKey (\n _ -> Set.member n live) env


rcNode :: Ctx -> Env -> Live -> MExpr -> RM MExpr
rcNode ctx env live e =
  let cls = mRep e
      node = MExpr cls
  in
  case mNode e of
    MLit (LString _) -> return (node (MOwn e))
    MLit _ -> return e
    MLocal n
      | not (refClass cls) -> return e
      | Map.member n env -> return (if Set.member n live then node (MDup [(n, cls)] e) else e)
      | otherwise -> return (node (MOwn e))                       -- a borrowed variable (captured by a lifted function)
    MGlobal c ->
      case Map.lookup c (cClones ctx) of
        Nothing -> failRc "an unknown clone" >> return e
        Just d
          | mdKind d == Value -> return (if refClass (mdResult d) || refClass cls then node (MOwn e) else e)
          | otherwise -> return (closureValue ctx env live e c)
    MKernel _ _ -> return e
    MCtor _ _ _ -> return (if refClass cls then node (MOwn e) else e)
    MCall h args -> rcCall ctx env live e h args
    MLam _ _ -> failRc "internal: a lambda reached the Rc pass" >> return e
    MIf bs final -> rcIf ctx env live cls bs final
    MLetVal n v b ->
      do  let liveV = Set.union live (Set.delete n (fvNames ctx b))
          v' <- rc ctx env liveV v
          let env1 = consumedAfter env liveV
          let env2 = if refClass (mRep v) then Map.insert n (mRep v) env1 else env1
          b' <- rc ctx env2 live b
          return (node (MLetVal n v' b'))
    MSeq a b ->
      do  let liveA = Set.union live (fvNames ctx b)
          a' <- rc ctx env liveA a
          let env1 = consumedAfter env liveA
          if refClass (mRep a)
            then
              do  t <- fresh                                       -- the value of `a` is not used: it is dropped at once
                  b' <- rc ctx (Map.insert t (mRep a) env1) live b
                  return (node (MLetVal t a' b'))
            else
              do  b' <- rc ctx env1 live b
                  return (node (MSeq a' b'))
    MCase s bs -> rcCase ctx env live cls s bs
    MAccess r f i ->
      withCall ctx env live cls [(useOf 'b' r, r)] Set.empty
        (\as -> case as of
                  [r'] -> let access = node (MAccess r' f i) in if refClass cls then node (MOwn access) else access
                  _ -> e)
    MUpdate _ _ -> failRc "a record update reached the Rc pass (not supported yet)" >> return e
    MRecord fs ->
      do  xs <- ownedArgs ctx env live (map snd fs)
          return (node (MRecord (zip (map fst fs) xs)))
    MTuple xs -> do { ys <- ownedArgs ctx env live xs; return (node (MTuple ys)) }
    MList [] -> return e
    MList xs -> do { ys <- ownedArgs ctx env live xs; return (node (MList ys)) }
    MDup _ _ -> failRc "internal: the Rc pass ran twice" >> return e
    MDrop _ _ -> failRc "internal: the Rc pass ran twice" >> return e
    MOwn _ -> failRc "internal: the Rc pass ran twice" >> return e


-- | a function used as a value: a static closure when it captures nothing; otherwise the closure object takes a count on each
-- captured reference (the variable is moved into it when this is its last use)
closureValue :: Ctx -> Env -> Live -> MExpr -> CloneId -> MExpr
closureValue ctx env live e c =
  let caps = [ (n, cc) | (n, cc) <- Map.findWithDefault [] c (cCaps ctx), refClass cc ]
      dups = [ (n, cc) | (n, cc) <- caps, not (Map.member n env) || Set.member n live ]
  in
  if null (Map.findWithDefault [] c (cCaps ctx))
    then MExpr (mRep e) (MOwn e)
    else if null dups then e else MExpr (mRep e) (MDup dups e)


-- THE CALLS

-- | how a callee treats an argument
data Use
  = UScalar                  -- not a reference: no counts
  | UOwn                     -- consumed by the callee
  | UBorrow                  -- only read by the callee: the caller keeps its count and drops it after the call when it is dead
  | UStatic                  -- a static object (string literal, constructor without fields): read as it is, no counts
  deriving (Eq)


useOf :: Char -> MExpr -> Use
useOf letter a
  | not (refClass (mRep a)) = UScalar
  | letter == 'o' = UOwn
  | staticValue a = UStatic
  | otherwise = UBorrow


staticValue :: MExpr -> Bool
staticValue x =
  case mNode x of
    MLit (LString _) -> True
    MCtor _ _ _ -> True
    _ -> False


isLocal :: MExpr -> Bool
isLocal a = case mNode a of { MLocal _ -> True; _ -> False }


isAtom :: MExpr -> Bool
isAtom a = case mNode a of { MLocal _ -> True; MLit _ -> True; MKernel _ _ -> True; _ -> False }


-- | the arguments of a constructor, tuple, record or list: all consumed
ownedArgs :: Ctx -> Env -> Live -> [MExpr] -> RM [MExpr]
ownedArgs ctx env live args =
  do  (_, args', _, _, _) <- callArgs ctx env live [ (if refClass (mRep a) then UOwn else UScalar, a) | a <- args ] Set.empty
      return args'


-- | evaluate the arguments of a call in order. Result: the temporaries to bind before the call (in order), the arguments, the
-- temporaries that are borrowed (dropped after the call), the variables that are borrowed, and the owned variables left after the
-- arguments. `extra` are variables the call uses without consuming them (the captured variables of a lifted callee).
callArgs :: Ctx -> Env -> Live -> [(Use, MExpr)] -> Set.Set String -> RM ([(String, Class, MExpr)], [MExpr], [(String, Class)], [String], Env)
callArgs ctx env0 live uses extra =
  do  let borrowedLocals = [ n | (u, MExpr c (MLocal n)) <- uses, u == UBorrow || u == UStatic, refClass c ]
      let liveBase = Set.union live (Set.union extra (Set.fromList borrowedLocals))
      let needTemps = or [ True | (UBorrow, a) <- uses, not (isLocal a) ]
      let later = drop 1 (scanr Set.union Set.empty [ fvNames ctx a | (_, a) <- uses ])
      let step (env, bs, as, ts) ((u, a), after) =
            do  let liveA = Set.union liveBase after
                let env' = consumedAfter env liveA
                case u of
                  UStatic -> return (env', bs, as ++ [a], ts)
                  UBorrow
                    | isLocal a -> return (env', bs, as ++ [a], ts)
                    | otherwise ->
                        do  v <- rc ctx env liveA a
                            t <- fresh
                            return (env', bs ++ [(t, mRep a, v)], as ++ [MExpr (mRep a) (MLocal t)], ts ++ [(t, mRep a)])
                  _ ->
                    do  v <- rc ctx env liveA a
                        if needTemps && not (isAtom a)
                          then do { t <- fresh; return (env', bs ++ [(t, mRep a, v)], as ++ [MExpr (mRep a) (MLocal t)], ts) }
                          else return (env', bs, as ++ [v], ts)
      (envEnd, binds, args', temps) <- foldM step (env0, [], [], []) (zip uses later)
      return (binds, args', temps, borrowedLocals, envEnd)


-- | a call that uses some arguments without consuming them: bind the temporaries, build the call from the arguments, and drop
-- afterwards what was only borrowed (the temporaries, the owned variables that are dead)
withCall :: Ctx -> Env -> Live -> Class -> [(Use, MExpr)] -> Set.Set String -> ([MExpr] -> MExpr) -> RM MExpr
withCall ctx env live cls uses extra build =
  do  (binds, args', temps, borrowedLocals, envEnd) <- callArgs ctx env live uses extra
      let drops = temps ++ [ (n, c) | n <- List.nub (borrowedLocals ++ Set.toList extra), Just c <- [Map.lookup n envEnd], not (Set.member n live) ]
      body <-
        if null drops
          then return (build args')
          else do  r <- fresh
                   return (MExpr cls (MLetVal r (build args') (MExpr cls (MDrop drops (MExpr cls (MLocal r))))))
      return (foldr (\(t, c, v) b -> MExpr cls (MLetVal t v b) `withClass` c) body binds)
  where
    withClass x _ = x


rcCall :: Ctx -> Env -> Live -> MExpr -> MExpr -> [MExpr] -> RM MExpr
rcCall ctx env live e h args =
  let cls = mRep e in
  case mNode h of
    MKernel name key -> rcKernel ctx env live e name key args
    MCtor _ _ _ ->
      if null args then return e
      else do { args' <- ownedArgs ctx env live args; return (MExpr cls (MCall h args')) }
    MGlobal c
      | Just d <- Map.lookup c (cClones ctx), mdKind d == Function, length args == length (mdParams d) ->
          let caps = Set.fromList [ n | (n, cc) <- Map.findWithDefault [] c (cCaps ctx), refClass cc ]
          in withCall ctx env live cls [ (if refClass (mRep a) then UOwn else UScalar, a) | a <- args ] caps (\as -> MExpr cls (MCall h as))
    _ -> rcApply ctx env live e h args


-- | a call of a function value: the function is borrowed, the arguments are consumed (`fic_apN`)
rcApply :: Ctx -> Env -> Live -> MExpr -> MExpr -> [MExpr] -> RM MExpr
rcApply ctx env live e h args =
  let cls = mRep e
      hUse = case mNode h of
        MGlobal c | Just d <- Map.lookup c (cClones ctx), mdKind d == Value -> UStatic         -- a global: read as it is
                  | null (Map.findWithDefault [] c (cCaps ctx)) -> UStatic                     -- a static closure
        _ -> if refClass (mRep h) then UBorrow else UScalar
      uses = (hUse, h) : [ (if refClass (mRep a) then UOwn else UScalar, a) | a <- args ]
  in withCall ctx env live cls uses Set.empty (\as -> case as of { f : rest -> MExpr cls (MCall f rest); [] -> e })


-- | the arguments of a kernel call by the letters of its signature
rcKernel :: Ctx -> Env -> Live -> MExpr -> String -> Key -> [MExpr] -> RM MExpr
rcKernel ctx env live e name key args =
  let cls = mRep e in
  case (name, args) of
    -- Elm's && and || evaluate the second operand only when the first does not decide: that is an `if`
    ("elm/core:Basics.and", [a, b]) -> rcNode ctx env live (MExpr cls (MIf [(a, b)] (MExpr cls (MCtor "False" 0 (Key [])))))
    ("elm/core:Basics.or", [a, b]) -> rcNode ctx env live (MExpr cls (MIf [(a, MExpr cls (MCtor "True" 1 (Key [])))] b))
    _ ->
      case kernelSig name key of
        Nothing -> failRc ("the kernel function " ++ name ++ " has no ownership signature") >> return e
        Just sigText
          | length sigText /= length args ->
              failRc ("the kernel function " ++ name ++ " has a signature of " ++ show (length sigText) ++ " letters and " ++ show (length args) ++ " arguments") >> return e
          | otherwise ->
              let uses = zipWith (\l a -> (useOf l a, a)) sigText args
                  kernel = MExpr (CUnit) (MKernel name key)
                  build as =
                    let call = MExpr cls (MCall (case mNode (headOf e) of { MKernel _ _ -> headOf e; _ -> kernel }) as)
                    in if kernelResultBorrowed name then MExpr cls (MOwn call) else call
              in withCall ctx env live cls uses Set.empty build
  where
    headOf x = case mNode x of { MCall h _ -> h; _ -> x }


-- IF AND CASE

-- | `if c1 then b1 else if c2 ...`: each condition is evaluated in the else branch of the one before
rcIf :: Ctx -> Env -> Live -> Class -> [(MExpr, MExpr)] -> MExpr -> RM MExpr
rcIf ctx env0 live cls branches final =
  do  (bs, final') <- go env0 branches
      return (MExpr cls (MIf bs final'))
  where
    go env [] = do { f <- rc ctx env live final; return ([], f) }
    go env ((c, b) : rest) =
      do  let afterC = Set.unions (fvNames ctx b : fvNames ctx final : [ Set.union (fvNames ctx c') (fvNames ctx b') | (c', b') <- rest ])
          let liveC = Set.union live afterC
          c' <- rc ctx env liveC c
          let env' = consumedAfter env liveC
          b' <- rc ctx env' live b
          (restBs, f) <- go env' rest
          return ((c', b') : restBs, f)


-- | a case: the scrutinee is a variable (a temporary when it is an expression); the variables a branch binds and uses are dup'd at
-- the start of the branch, and what is dead there (the scrutinee too, usually) is dropped
rcCase :: Ctx -> Env -> Live -> Class -> MExpr -> [(MPat, MExpr)] -> RM MExpr
rcCase ctx env live cls s bs =
  case mNode s of
    MLocal _ -> do { bs' <- branches env; return (MExpr cls (MCase s bs')) }
    _ ->
      do  t <- fresh
          let liveS = Set.union live (Set.unions [ Set.difference (fvNames ctx b) (Set.fromList (map fst (patBinders p))) | (p, b) <- bs ])
          s' <- rc ctx env liveS s
          let env1 = consumedAfter env liveS
          let env2 = if refClass (mRep s) then Map.insert t (mRep s) env1 else env1
          bs' <- branches env2
          return (MExpr cls (MLetVal t s' (MExpr cls (MCase (MExpr (mRep s) (MLocal t)) bs'))))
  where
    branches envB =
      mapM (\(p, b) ->
              do  let used = fvNames ctx b
                  let dups = [ (v, c) | (v, c) <- patBinders p, refClass c, Set.member v used ]
                  b' <- rc ctx (Map.union (Map.fromList dups) envB) live b
                  return (p, if null dups then b' else MExpr (mRep b) (MDup dups b')))
           bs


-- FAULT INJECTION (the tests of the checker)

-- | the program with the n-th `MDup` or `MDrop` node (counting in order through the clones) removed: a program that the checker must
-- reject, because every count the pass inserts is needed. `Nothing` when there are not that many nodes.
rcMutate :: Int -> MProgram -> Maybe MProgram
rcMutate n program =
  let (clones', total) = runState (mapM mutDef (mpClones program)) 0
  in if total > n then Just program { mpClones = clones' } else Nothing
  where
    mutDef d =
      case mdBody d of
        Nothing -> return d
        Just b -> do { b' <- mut b; return d { mdBody = Just b' } }
    mut :: MExpr -> State Int MExpr
    mut e =
      case mNode e of
        MDup vs b -> site (MDup vs) b e
        MDrop vs b -> site (MDrop vs) b e
        node -> do { node' <- mutNode node; return e { mNode = node' } }
    site con b e =
      do  k <- get
          put (k + 1)
          b' <- mut b
          return (if k == n then b' else e { mNode = con b' })
    pair f x = do { x' <- mut x; return (f, x') }
    mutNode node =
      case node of
        MCall f as -> do { f' <- mut f; as' <- mapM mut as; return (MCall f' as') }
        MLam ps b -> do { b' <- mut b; return (MLam ps b') }
        MIf bs f -> do { bs' <- mapM (\(c, b) -> do { c' <- mut c; b' <- mut b; return (c', b') }) bs; f' <- mut f; return (MIf bs' f') }
        MLetVal v x b -> do { x' <- mut x; b' <- mut b; return (MLetVal v x' b') }
        MSeq a b -> do { a' <- mut a; b' <- mut b; return (MSeq a' b') }
        MCase sc bs -> do { sc' <- mut sc; bs' <- mapM (\(pt, b) -> do { b' <- mut b; return (pt, b') }) bs; return (MCase sc' bs') }
        MAccess r f i -> do { r' <- mut r; return (MAccess r' f i) }
        MUpdate r fs -> do { r' <- mut r; fs' <- mapM (\(f, x) -> pair f x) fs; return (MUpdate r' fs') }
        MRecord fs -> do { fs' <- mapM (\(f, x) -> pair f x) fs; return (MRecord fs') }
        MTuple xs -> MTuple <$> mapM mut xs
        MList xs -> MList <$> mapM mut xs
        MOwn b -> MOwn <$> mut b
        other -> return other
