{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE PatternGuards #-}
module Ficcus.Mono.Inline
  ( inlineProgram
  , inlineStats
  )
  where


-- Ficcus, stage (iv) slice S7: a constructor value that is made by a known small function and matched at once is never built.
--
-- `Array.get i a` allocates a `Just` that `Maybe.withDefault 0` or a `case` takes apart in the next step: 171 M of the 178 M
-- allocations of fannkuch (docs/STAGE4-S7.md). The pass runs on the specializer's output, before the Rc pass (only for counted
-- builds: the no-RC C text is the oracle and does not change), and knows nothing about `Array` or `Maybe`. Two kinds of clones:
--
--   producer   a small function that is not recursive and has no local functions, whose result on every path is a constructor
--              application (`Array.get`, `List.head`, `Maybe.map`, `Result.map`, ...) or a call of a producer;
--   consumer   such a function whose body is a `case` on one of its parameters (`Maybe.withDefault`, `Maybe.map`, `Maybe.andThen`,
--              `Result.withDefault`, ...).
--
-- Rules, applied bottom-up in every body:
--
--   (A) `case E of branches`, where E is a call of a producer or an expression whose result on every path is a constructor
--       application: the producer's body is put in place of the call and the `case` is pushed to its leaves, where the constructor is
--       known: each leaf becomes the branch it selects with the pattern variables bound to the constructor's arguments.
--   (B) `consumer .. E ..` with E as in (A) in the position of the parameter the consumer matches: the consumer's body is put in
--       place of the call, then (A).
--
-- Evaluation order is kept: arguments that are not variables or literals are bound by `let` in their order; the matched argument
-- of a consumer goes directly into the `case` only when the arguments after it are variables or literals. A branch is copied to
-- two leaves only when it is tiny; `if c then K a else K b` is first turned into `K (if c then a else b)` so that `Array.get` has
-- one `Just` leaf. Where a condition does not hold the expression is left as it was. The result is an ordinary Mono program: the
-- Rc pass counts it and RcCheck verifies it like any other. `FICCUS_NO_INLINE=1` switches the pass off.


import Control.Monad (foldM, forM)
import Control.Monad.State.Strict (State, get, put, runState)
import qualified Data.Graph as Graph
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing)
import qualified Data.Set as Set
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)

import Ficcus.Mono.Class
import Ficcus.Mono.Free (captures, patVars)
import Ficcus.Mono.Known (knownOn)
import Ficcus.Mono.Ir


{-# NOINLINE inlineOn #-}
inlineOn :: Bool
inlineOn = unsafePerformIO (fmap (/= Just "1") (lookupEnv "FICCUS_NO_INLINE"))


-- H16 W5 (rule 1a): `FICCUS_NO_LIFTED_INLINE=1` keeps the lifted clones out of the table (as before); it only matters with the Known pass on
{-# NOINLINE liftedInlineOn #-}
liftedInlineOn :: Bool
liftedInlineOn = unsafePerformIO (fmap (/= Just "1") (lookupEnv "FICCUS_NO_LIFTED_INLINE"))


-- H16 W5 (rule 1c): `FICCUS_NO_IDENT=1` switches the case identity rule off (it also needs the Known pass on)
{-# NOINLINE identOn #-}
identOn :: Bool
identOn = unsafePerformIO (fmap (/= Just "1") (lookupEnv "FICCUS_NO_IDENT"))


-- H16 W6 (rule A, relaxed copy limit): `FICCUS_NO_COPYOK2=1` restores the old limit (a consumer branch used by more than one leaf of the
-- producer must be tiny); it also needs the Known pass on
{-# NOINLINE copyOk2On #-}
copyOk2On :: Bool
copyOk2On = unsafePerformIO (fmap (/= Just "1") (lookupEnv "FICCUS_NO_COPYOK2"))


-- the state: a counter for fresh names, and the number of rewrites done (rule A, rule B)
type M = State (Int, Int, Int)


data Tab =
  Tab
    { tDefs :: Map.Map CloneId MDef        -- the clones that may be put in place of a call
    , tProd :: Set.Set CloneId             -- producers
    , tLifted :: Set.Set CloneId           -- lifted clones (they use variables of their owner by name)
    , tQuiet :: Set.Set CloneId            -- clones that cannot print (no `Debug` kernel, no call of an unknown function, transitively)
    , tOwner :: Map.Map CloneId CloneId    -- the owner of each lifted clone
    , tCur :: Maybe CloneId                -- the clone whose body is being rewritten
    , tScc :: Map.Map CloneId Int          -- H16 W5: the call cycle (strongly connected component with a cycle) of each clone in one
    , tAdm :: Set.Set CloneId              -- H16 W5: the lifted clones admitted to the table
    }


sizeLimit :: Int
sizeLimit = 80


-- | the program with rules (A) and (B) applied in every body
inlineProgram :: MProgram -> MProgram
inlineProgram program = fst (inlineStats program)


-- | the same, with the number of applications of rule (A) and of rule (B)
inlineStats :: MProgram -> (MProgram, (Int, Int))
inlineStats program
  | not inlineOn = (program, (0, 0))
  | otherwise =
      let clones = mpClones program
          tab = table clones
          (clones', (_, a, b)) = runState (mapM (inlineDef tab (mpMain program)) clones) (0, 0, 0)
          -- the clones of `Vector.update` that rule (U) wrote out everywhere are dropped (nothing else refers to them)
          referenced = Set.fromList (concat [ exprRefs bd | d <- clones', Just bd <- [mdBody d] ] ++ concatMap mdNeeds clones' ++ maybe [] pure (mpMain program))
          live d = mdName d /= updateName || Set.member (mdClone d) referenced
      in (program { mpClones = filter live clones' }, (a, b))


table :: [MDef] -> Tab
table clones =
  let owners = Set.fromList [ o | d <- clones, Just o <- [mdLifted d] ]
      lifted = Set.fromList [ mdClone d | d <- clones, mdLifted d /= Nothing ]
      -- H16 W3: with the Known pass on, a reference to a lifted clone that captures nothing does not disqualify a body (it needs no scope)
      caps = if knownOn then captures clones else Map.empty
      liftedCap = Set.fromList [ mdClone d | d <- clones, mdLifted d /= Nothing, not (knownOn && null (Map.findWithDefault [("", CRef)] (mdClone d) caps)) ]
      -- H16 W5: a lifted clone that captures nothing (the Known pass's copies of the parser combinators' lambdas) may be inlined like a global
      -- function. A clone with captures stays out (its body names its owner's variables). A clone is never put in place of a call inside its own
      -- call cycle (`inlineDef` drops it from the table there; a self call is refused below).
      sccs = Map.fromList [ (c, i) | (i, Graph.CyclicSCC cs) <- zip [0 :: Int ..] (Graph.stronglyConnComp [ (mdClone d, mdClone d, maybe [] exprRefs (mdBody d)) | d <- clones ]), c <- cs ]
      liftedFree d = knownOn && liftedInlineOn && mdLifted d /= Nothing && null (Map.findWithDefault [("", CRef)] (mdClone d) caps)
      ok d = mdKind d == Function && (mdLifted d == Nothing || liftedFree d) && not (Set.member (mdClone d) owners)
             && case mdBody d of
                  Just b -> size b <= sizeLimit && mdClone d `notElem` exprRefs b && not (hasLam b) && not (hasRecordPat b) && not (any (`Set.member` liftedCap) (exprRefs b))
                  Nothing -> False
      defs = Map.fromList [ (mdClone d, d) | d <- clones, ok d ]
      leafOk ps l = isCtorApp l || (case mNode l of { MCall (MExpr _ (MGlobal p)) _ -> Set.member p ps; _ -> False })
      -- least fixed point from the clones whose leaves are all constructor applications
      p0 = Set.fromList [ c | (c, d) <- Map.toList defs, Just b <- [mdBody d], all (\l -> isCtorApp l) (leaves b) ]
      prod = growFrom p0
      growFrom ps =
        let ps' = Set.union ps (Set.fromList [ c | (c, d) <- Map.toList defs, Just b <- [mdBody d], all (leafOk ps) (leaves b) ])
        in if ps' == ps then ps else growFrom ps'
      -- greatest fixed point: a clone is quiet when its body calls only kernels other than `Debug.*`, constructors and quiet clones
      quiet0 = Set.fromList [ mdClone d | d <- clones, isJust (mdBody d) ]
      shrink qs =
        let qs' = Set.fromList [ mdClone d | d <- clones, Set.member (mdClone d) qs, Just b <- [mdBody d], quietIn qs b ]
        in if qs' == qs then qs else shrink qs'
  in Tab defs prod lifted (shrink quiet0) (Map.fromList [ (mdClone d, o) | d <- clones, Just o <- [mdLifted d] ]) Nothing
        sccs (Set.filter (`Map.member` defs) lifted)


-- | an expression that prints nothing and calls no unknown function (so it may be skipped when its value is not needed)
quietIn :: Set.Set CloneId -> MExpr -> Bool
quietIn qs e =
  (case mNode e of
     MCall f _ ->
       case mNode f of
         MKernel k _ -> not (isDebug k)
         MCtor _ _ _ -> True
         MGlobal c -> Set.member c qs
         _ -> False
     MKernel k _ -> not (isDebug k)
     MLam _ _ -> False
     _ -> True)
  && all (quietIn qs) (case mNode e of { MCall f args | isHead f -> args; _ -> children e })
  where
    isHead f = case mNode f of { MKernel _ _ -> True; MCtor _ _ _ -> True; MGlobal _ -> True; _ -> False }
    isDebug k = "Debug." `List.isInfixOf` k


size :: MExpr -> Int
size e = 1 + sum (map size (children e))


hasLam :: MExpr -> Bool
hasLam e = case mNode e of { MLam _ _ -> True; _ -> any hasLam (children e) }


-- a record pattern names its variables after the fields: they cannot be renamed
hasRecordPat :: MExpr -> Bool
hasRecordPat e =
  (case mNode e of { MCase _ bs -> any (rec . fst) bs; _ -> False }) || any hasRecordPat (children e)
  where
    rec (MPat _ p) =
      case p of
        PRecord _ -> True
        PCtor _ _ ps -> any rec ps
        PTuple ps -> any rec ps
        PCons a b -> rec a || rec b
        PAlias q _ -> rec q
        _ -> False


-- | the expressions that give the result of an expression (through `if`, `case`, `let` and sequences)
leaves :: MExpr -> [MExpr]
leaves e =
  case mNode e of
    MIf arms el -> concatMap (leaves . snd) arms ++ leaves el
    MCase _ bs -> concatMap (leaves . snd) bs
    MLetVal _ _ b -> leaves b
    MSeq _ b -> leaves b
    _ -> [e]


-- | a constructor application: name, tag, arguments
ctorApp :: MExpr -> Maybe (String, Int, [MExpr])
ctorApp e =
  case mNode e of
    MCtor n t _ -> Just (n, t, [])
    MCall (MExpr _ (MCtor n t _)) args -> Just (n, t, args)
    _ -> Nothing


isCtorApp :: MExpr -> Bool
isCtorApp e = isJust (ctorApp e)


atom :: MExpr -> Bool
atom e = case mNode e of { MLocal _ -> True; MLit _ -> True; _ -> False }


uses :: String -> MExpr -> Int
uses n e = case mNode e of { MLocal m -> if m == n then 1 else 0; _ -> sum (map (uses n) (children e)) }


inlineDef :: Tab -> Maybe CloneId -> MDef -> M MDef
inlineDef tab root d =
  case mdBody d of
    Just body | Just (mdClone d) /= root ->
      do  let me = mdClone d
              -- a lifted clone of the same call cycle as this body is not put in place of a call
              keep c = not (Set.member c (tAdm tab)) || case (Map.lookup c (tScc tab), Map.lookup me (tScc tab)) of { (Just i, Just j) -> i /= j; _ -> True }
          body' <- rw tab { tCur = Just me, tDefs = Map.filterWithKey (\c _ -> keep c) (tDefs tab), tProd = Set.filter keep (tProd tab) } body
          return d { mdBody = Just body' }
    _ -> return d


-- bottom-up: the sub-expressions first, then the rules at this node
rw :: Tab -> MExpr -> M MExpr
rw tab (MExpr cls node) =
  do  node' <- sub node
      let e = MExpr cls node'
      case node' of
        MCase scrut bs | candidate tab scrut ->
          do  saved <- get
              r <- ruleA tab cls noRe scrut bs
              case r of
                Just e' -> do { (k, a, b) <- get; put (k, a + 1, b); return e' }
                Nothing -> put saved >> return e
        MCase (MExpr _ (MTuple es)) [(MPat _ (PTuple qs), x), (MPat _ PWild, dflt)]
          | length es == length qs, any (candidate tab) es, all simplePat qs, all (quietIn (tQuiet tab)) (drop 1 es), tinyCopy tab dflt ->
          do  saved <- get
              r <- ruleT tab cls (zip es qs) x dflt
              case r of
                Just e' -> do { (k, a, b) <- get; put (k, a + 1, b); return e' }
                Nothing -> put saved >> return e
        -- rule (L), decision D6: `Vector.fromList [x1, .., xn]` builds the vector directly (no list): push the elements into a vector of room n
        MCall (MExpr kc (MKernel "elm/core:Vector.fromList" key)) [MExpr _ (MList xs)] | not (null xs) ->
          do  (n0, a, b) <- get
              put (n0, a + 1, b)
              names <- forM xs (const (fresh "vl"))
              base <- fresh "vl"
              let kern nm = MExpr kc (MKernel nm key)
                  start = MExpr cls (MCall (kern "elm/core:Vector.withCapacity") [MExpr CI64 (MLit (LInt (fromIntegral (length xs))))])
                  prevs = base : names
                  final = last (base : names)
                  chain = foldr (\(x, nm, prev) acc -> MExpr cls (MLetVal nm (MExpr cls (MCall (kern "elm/core:Vector.push") [x, MExpr cls (MLocal prev)])) acc))
                                (MExpr cls (MLocal final)) (zip3 xs names prevs)
              return (MExpr cls (MLetVal base start chain))
        -- rule (U): `Vector.update i f v` with a lambda `f` of the same definition is written out, so that `f x` is a direct call
        MCall (MExpr _ (MGlobal c)) [ai, MExpr _ (MGlobal l), av]
          | Just def <- Map.lookup c (tDefs tab), mdName def == updateName, Just body <- mdBody def, [(pi', _), (pf, _), (pv, _)] <- mdParams def
          , mdResult def == cls, canCallDirect tab l ->
          do  binds <- forM [ (pi', ai), (pv, av) ] $ \(q, a) -> if atom a then return (q, Left a) else do { q' <- fresh q; return (q, Right (q', a)) }
              let env = Map.fromList ([ (q, either mNode (\(q', _) -> MLocal q') b) | (q, b) <- binds ] ++ [ (pf, MGlobal l) ])
              body' <- freshen env body
              (n, a, b) <- get
              put (n, a + 1, b)
              return (foldr (\(_, b') acc -> case b' of { Left _ -> acc; Right (q', x) -> MExpr (mRep acc) (MLetVal q' x acc) }) body' binds)
        MCall (MExpr _ (MGlobal c)) args | Just def <- Map.lookup c (tDefs tab), Just (k, bs) <- consumerOf def
                                         , length args == length (mdParams def), candidate tab (args !! k) ->
          do  saved <- get
              r <- ruleB tab cls def k bs args
              case r of
                Just e' -> do { (n, a, b) <- get; put (n, a, b + 1); return e' }
                Nothing -> put saved >> return e
        -- rule (I), H16 W5 rule 1c: `case x of C y1 .. yn -> C y1 .. yn` returns `x` (also retyped, `Bad c m` at `Step a` rebuilt at `Step b`)
        MCase scrut bs | knownOn && identOn, Just mk <- caseIdentity cls scrut bs -> mk
        _ -> return e
  where
    sub = descend (rw tab)


-- | rule (I): a branch `C y1 .. yn -> C y1 .. yn` (the same constructor, the pattern variables in order, nothing else in the branch) of a
-- `case` on a heap object gives the scrutinee itself. The fields of the rebuilt cell are the fields of the matched one, so the cell is the same
-- at any key whose constructor has these field classes; the pattern variable and the argument are one local, so their classes are equal. The
-- scrutinee is let-bound first when it is not a variable. A `case` whose every branch is such an identity is the scrutinee.
caseIdentity :: Class -> MExpr -> [(MPat, MExpr)] -> Maybe (M MExpr)
caseIdentity cls scrut bs
  | mRep scrut /= CRef || not (any isJust ids) = Nothing
  | all isJust ids = Just (return scrut)
  | otherwise =
      case mNode scrut of
        MLocal x | all (notBound x) bs -> Just (return (rebuild x scrut))
                 | otherwise -> Nothing
        _ -> Just (do { v <- fresh "id"; return (MExpr cls (MLetVal v scrut (rebuild v (MExpr CRef (MLocal v))))) })
  where
    ids = map identity bs
    identity (MPat pc (PCtor n t ps), MExpr bc (MCall (MExpr _ (MCtor n' t' _)) args))
      | n == n', t == t', not (null ps), length ps == length args, bc == CRef, pc == CRef
      , Just vs <- mapM patVar ps, and (zipWith sameLocal vs args), distinct vs = Just (n, t, ps)
    identity _ = Nothing
    patVar (MPat c (PVar v)) = Just (v, c)
    patVar _ = Nothing
    sameLocal (v, c) (MExpr ac (MLocal w)) = v == w && c == ac
    sameLocal _ _ = False
    distinct vs = length (List.nub (map fst vs)) == length vs
    notBound x (MPat _ p, _) = x `notElem` patVars (MPat CRef p)
    rebuild x s' = MExpr cls (MCase s' (zipWith (rewrite (MExpr CRef (MLocal x))) ids bs))
    rewrite x (Just (n, t, ps)) (MPat pc _, _) = (MPat pc (PCtor n t [ MPat c PWild | MPat c _ <- ps ]), x)
    rewrite _ Nothing b = b


-- the definition that rule (U) writes out
updateName :: String
updateName = "author/project:Vector.update"


-- a lifted lambda may be called by name where its owner's variables are in scope: in the body of its owner
canCallDirect :: Tab -> CloneId -> Bool
canCallDirect tab l =
  case Map.lookup l (tOwner tab) of
    Nothing -> True
    Just o -> Just o == tCur tab


-- an expression that rule (A) can take apart: a call of a producer, or constructor applications (or producer calls) on every path,
-- at least one of them not the bare expression itself unless it is a constructor application
candidate :: Tab -> MExpr -> Bool
candidate tab e = all ok (leaves e)
  where
    ok l = isCtorApp l || isJust (producerCall tab l)


producerCall :: Tab -> MExpr -> Maybe (MDef, [MExpr])
producerCall tab e =
  case mNode e of
    MCall (MExpr _ (MGlobal p)) args | Set.member p (tProd tab), Just d <- Map.lookup p (tDefs tab)
                                     , length args == length (mdParams d), mdResult d == mRep e
                                     , and [ mRep a == c | (a, (_, c)) <- zip args (mdParams d) ] -> Just (d, args)
    _ -> Nothing


-- a consumer: the body is a `case` on a parameter that is used nowhere else; the index of the parameter and the branches
consumerOf :: MDef -> Maybe (Int, [(MPat, MExpr)])
consumerOf d =
  case mdBody d of
    Just (MExpr _ (MCase (MExpr _ (MLocal p)) bs)) | [k] <- [ i | (i, (n, _)) <- zip [0 ..] (mdParams d), n == p ]
                                                 , sum (map (uses p . snd) bs) == 0 -> Just (k, bs)
    _ -> Nothing


-- RULE (T): `case (e1, .., en) of (q1, .., qn) -> x; _ -> d` becomes nested cases, so that rule (A) applies to each component.
-- A component after the first is evaluated only when the earlier ones match (it is quiet: nothing is printed either way)


ruleT :: Tab -> Class -> [(MExpr, MPat)] -> MExpr -> MExpr -> M (Maybe MExpr)
ruleT tab cls parts x dflt =
  do  (e, n) <- foldM step (x, 0 :: Int) (reverse parts)
      return (if n > 0 then Just e else Nothing)
  where
    step (acc, n) (e, q@(MPat qc pat)) =
      case pat of
        PWild -> return (if atom e then acc else MExpr cls (MSeq e acc), n)
        PVar v | qc == mRep e -> return (MExpr cls (MLetVal v e acc), n)
        PVar _ -> return (MExpr cls (MCase e [(q, acc)]), n)
        _ ->
          do  let bs = [(q, acc), (MPat qc PWild, dflt)]
              r <- if candidate tab e then ruleA tab cls noRe e bs else return Nothing
              return (case r of
                        Just e' -> (e', n + 1)
                        Nothing -> (MExpr cls (MCase e bs), n))


-- H16 W6: a branch that may be copied to a few leaves: small, binds nothing itself (no renaming needed), no lifted clone in it
smallCopy :: Tab -> MExpr -> Bool
smallCopy tab b = size b <= copyMaxSize && null (binders b) && not (any (`Set.member` tLifted tab) (exprRefs b))


copyMaxSize, copyMaxUses :: Int
copyMaxSize = 24
copyMaxUses = 4


tinyCopy :: Tab -> MExpr -> Bool
tinyCopy tab b = size b <= 6 && null (binders b) && not (any (`Set.member` tLifted tab) (exprRefs b))


-- RULE (B)


ruleB :: Tab -> Class -> MDef -> Int -> [(MPat, MExpr)] -> [MExpr] -> M (Maybe MExpr)
ruleB tab cls def k bs args
  | not (all atom (drop (k + 1) args)) = return Nothing
  | mRep (args !! k) /= snd (mdParams def !! k) = return Nothing
  | not (and [ mRep a == c || (c == CRef && isStruct (mRep a)) | (i, (a, (_, c))) <- zip [0 :: Int ..] (zip args (mdParams def)), i /= k ]) = return Nothing
  | not (mdResult def == cls || (mdResult def == CRef && isStruct cls)) = return Nothing
  | otherwise =
      do  -- the parameters other than the matched one: a variable or literal of the parameter's class is substituted, anything else is
          -- bound by a let. A struct given for a parameter of a polymorphic clone (class ref: the clone would get it in a box) keeps
          -- its own class (`Re`)
          binds <- forM [ (p, c, a) | (i, ((p, c), a)) <- zip [0 :: Int ..] (zip (mdParams def) args), i /= k ] $ \(p, c, a) ->
            if atom a && mRep a == c then return (p, Left a) else do { p' <- fresh p; return (p, Right (p', a, c)) }
          let env0 = Map.fromList [ (p, either mNode (\(p', _, _) -> MLocal p') b) | (p, b) <- binds ]
          let re = Re (Map.fromList [ (p', mRep a) | (_, Right (p', a, c)) <- binds, mRep a /= c ]) (if mdResult def == cls then Nothing else Just cls)
          bs' <- forM bs $ \(pat, body) ->
            do  (pat', env) <- freshPat env0 pat
                body' <- freshen env body
                return (pat', body')
          inner <- ruleA tab cls re (args !! k) bs'
          case inner of
            Nothing -> return Nothing
            Just e ->
              -- an unused parameter's argument is still evaluated
              return (Just (foldr (\(p, b) acc ->
                                      case b of
                                        Left _ -> acc
                                        Right (p', a, _) | usedIn p bs -> MExpr (mRep acc) (MLetVal p' a acc)
                                                         | atom a -> acc
                                                         | otherwise -> MExpr (mRep acc) (MSeq a acc))
                                  e binds))
  where
    usedIn p branches = sum (map (uses p . snd) branches) > 0


-- | what changes when the body of a polymorphic clone is used at a struct type: the clone holds the struct in a box (class ref);
-- here these variables hold the struct itself, and the result has the given class instead of ref
data Re = Re { reVars :: Map.Map String Class, reRes :: Maybe Class }


noRe :: Re
noRe = Re Map.empty Nothing


isStruct :: Class -> Bool
isStruct c = case c of { CStruct _ -> True; _ -> False }


-- a branch body with the variables of `vs` at their struct class. Such a variable may be a direct argument of a call (the
-- generator converts the arguments of every call to what the callee takes) and, when the class of the result changes, the result
-- itself; in any other place the rewrite is given up
reclass :: Map.Map String Class -> Maybe Class -> MExpr -> Maybe MExpr
reclass vs res e0
  | Map.null vs && res == Nothing = Just e0
  | otherwise = top e0
  where
    new c = maybe c id res
    top e@(MExpr c n) =
      case n of
        MLocal v | Just vc <- Map.lookup v vs -> if res == Just vc then Just (MExpr vc n) else Nothing
        MIf arms el -> MExpr (new c) <$> (MIf <$> mapM (\(a, b) -> (,) <$> inner a <*> top b) arms <*> top el)
        MCase sc bs -> MExpr (new c) <$> (MCase <$> inner sc <*> mapM (\(p, b) -> (,) p <$> top b) bs)
        MLetVal x v b -> MExpr (new c) <$> (MLetVal x <$> inner v <*> top b)
        MSeq a b -> MExpr (new c) <$> (MSeq <$> inner a <*> top b)
        _ | res == Nothing -> inner e
          | otherwise -> Nothing
    inner (MExpr c n) =
      case n of
        MLocal v | Map.member v vs -> Nothing
        MCall f args -> MExpr c <$> (MCall <$> inner f <*> mapM arg args)
        _ -> MExpr c <$> descend inner n
    arg e@(MExpr _ n) =
      case n of
        MLocal v | Just vc <- Map.lookup v vs -> Just (MExpr vc n)
        _ -> inner e


-- the sub-expressions of a node replaced
descend :: Applicative f => (MExpr -> f MExpr) -> MNode -> f MNode
descend go n =
  case n of
    MCall f args -> MCall <$> go f <*> traverse go args
    MLam ps b -> MLam ps <$> go b
    MIf arms el -> MIf <$> traverse (\(c, b) -> (,) <$> go c <*> go b) arms <*> go el
    MLetVal x v b -> MLetVal x <$> go v <*> go b
    MSeq a b -> MSeq <$> go a <*> go b
    MCase sc bs -> MCase <$> go sc <*> traverse (\(p, b) -> (,) p <$> go b) bs
    MAccess x f i -> (\x' -> MAccess x' f i) <$> go x
    MUpdate x fs -> MUpdate <$> go x <*> traverse (\(f, v) -> (,) f <$> go v) fs
    MRecord fs -> MRecord <$> traverse (\(f, v) -> (,) f <$> go v) fs
    MTuple xs -> MTuple <$> traverse go xs
    MList xs -> MList <$> traverse go xs
    _ -> pure n


-- RULE (A)


-- `case scrut of bs` with a result of class `cls`: Nothing when a condition does not hold
ruleA :: Tab -> Class -> Re -> MExpr -> [(MPat, MExpr)] -> M (Maybe MExpr)
ruleA tab cls re scrut bs
  | not (all (simplePat . fst) bs) = return Nothing
  | otherwise =
      do  expanded <- expand tab (4 :: Int) scrut
          case expanded of
            Nothing -> return Nothing
            Just e0 ->
              let e = merge e0
                  picks = map (pick bs) (leaves e)
              in if any isNothing picks then return Nothing
                 else
                   let counts = Map.fromListWith (+) [ (i, 1 :: Int) | Just i <- picks ]
                       copyOk i = Map.findWithDefault 0 i counts <= 1 || tiny (snd (bs !! i))
                                  || (knownOn && copyOk2On && Map.findWithDefault 0 i counts <= copyMaxUses && smallCopy tab (snd (bs !! i)))
                   in if all copyOk (Map.keys counts) then push tab cls re counts bs e else return Nothing
  where
    tiny = tinyCopy tab


simplePat :: MPat -> Bool
simplePat (MPat _ p) =
  case p of
    PWild -> True
    PVar _ -> True
    PCtor _ _ ps -> all irrefutable ps
    _ -> False


-- a pattern that always matches and whose variables can be renamed: a variable, a wildcard, a tuple of such
irrefutable :: MPat -> Bool
irrefutable (MPat _ q) =
  case q of
    PWild -> True
    PVar _ -> True
    PTuple qs -> all irrefutable qs
    _ -> False


-- the index of the branch a constructor application selects
pick :: [(MPat, MExpr)] -> MExpr -> Maybe Int
pick bs leaf =
  case ctorApp leaf of
    Nothing -> Nothing
    Just (name, tag, args) ->
      case [ i | (i, (MPat _ p, _)) <- zip [0 ..] bs, matches p ] of
        i : _ | fits (fst (bs !! i)) -> Just i
        _ -> Nothing
      where
        matches p = case p of { PWild -> True; PVar _ -> True; PCtor n t _ -> n == name && t == tag; _ -> False }
        -- the classes of the arguments are those of the pattern (a struct in a polymorphic field is boxed on one side only)
        fits (MPat pc p) =
          case p of
            PCtor _ _ ps -> length ps == length args && and [ mpRep q == mRep a || unboxes (mRep a) q || boxes (mRep a) q | (q, a) <- zip ps args ]
            PVar _ -> pc == mRep leaf
            _ -> True


-- a struct held in a polymorphic field is a box (class ref) in the constructor application and a struct for the pattern
unboxes :: Class -> MPat -> Bool
unboxes from q = from == CRef && isStruct (mpRep q) && irrefutable q


-- the other way round (the branch is the body of a polymorphic clone, the argument is the struct): see `Re`
boxes :: Class -> MPat -> Bool
boxes from (MPat to p) = isStruct from && to == CRef && (case p of { PVar _ -> True; PWild -> True; _ -> False })


-- producer calls at the leaves are replaced by the producer's body, a few levels deep
expand :: Tab -> Int -> MExpr -> M (Maybe MExpr)
expand tab fuel e@(MExpr cls node) =
  case node of
    MIf arms el ->
      do  arms' <- mapM (\(c, b) -> fmap ((,) c) <$> expand tab fuel b) arms
          el' <- expand tab fuel el
          return (MExpr cls <$> (MIf <$> sequence arms' <*> el'))
    MCase s bs ->
      do  bs' <- mapM (\(p, b) -> fmap ((,) p) <$> expand tab fuel b) bs
          return (MExpr cls . MCase s <$> sequence bs')
    MLetVal x v b -> fmap (MExpr cls . MLetVal x v) <$> expand tab fuel b
    MSeq a b -> fmap (MExpr cls . MSeq a) <$> expand tab fuel b
    _ | isCtorApp e -> return (Just e)
      | fuel > 0, Just (d, args) <- producerCall tab e, Just body <- mdBody d ->
          do  inst <- instantiate d body args
              expand tab (fuel - 1) inst
      | otherwise -> return Nothing


-- the body of a clone with its parameters replaced: a variable or literal is substituted, anything else is bound by a let, in the
-- order of the arguments; every variable the body binds gets a fresh name
instantiate :: MDef -> MExpr -> [MExpr] -> M MExpr
instantiate d body args =
  do  binds <- forM (zip (mdParams d) args) $ \((p, _), a) ->
        if atom a then return (p, Left a) else do { p' <- fresh p; return (p, Right (p', a)) }
      let env = Map.fromList [ (p, either mNode (\(p', _) -> MLocal p') b) | (p, b) <- binds ]
      body' <- freshen env body
      return (foldr (\(p, b) acc ->
                        case b of
                          Left _ -> acc
                          Right (p', a) | uses p body > 0 -> MExpr (mRep acc) (MLetVal p' a acc)
                                        | otherwise -> MExpr (mRep acc) (MSeq a acc))
                    body' binds)


-- `if c then K a else K b` at the end of an `if` becomes `K (if c then a else b)` (one argument, same class)
merge :: MExpr -> MExpr
merge e@(MExpr cls node) =
  case node of
    MIf arms el ->
      let arms' = [ (c, merge b) | (c, b) <- arms ]
          el' = merge el
      in case (reverse arms', ctorApp1 el') of
           ((c, b) : before, Just (f, y)) | Just (g, x) <- ctorApp1 b, sameCtor f g, mRep x == mRep y ->
             let inner = MExpr (mRep x) (MIf [(c, x)] y)
                 joined = MExpr (mRep el') (MCall f [inner])
             in if null before then joined else merge' (MExpr cls (MIf (reverse before) joined))
           _ -> MExpr cls (MIf arms' el')
    MCase s bs -> MExpr cls (MCase s [ (p, merge b) | (p, b) <- bs ])
    MLetVal x v b -> MExpr cls (MLetVal x v (merge b))
    MSeq a b -> MExpr cls (MSeq a (merge b))
    _ -> e
  where
    -- again on the shortened `if` (its arms are merged already)
    merge' x@(MExpr c n) =
      case n of
        MIf arms el | ((cnd, b) : before, Just (f, y)) <- (reverse arms, ctorApp1 el), Just (g, v) <- ctorApp1 b, sameCtor f g, mRep v == mRep y ->
          let inner = MExpr (mRep v) (MIf [(cnd, v)] y)
              joined = MExpr (mRep el) (MCall f [inner])
          in if null before then joined else merge' (MExpr c (MIf (reverse before) joined))
        _ -> x
    ctorApp1 x = case mNode x of { MCall f@(MExpr _ (MCtor _ _ _)) [a] -> Just (f, a); _ -> Nothing }
    sameCtor f g = case (mNode f, mNode g) of { (MCtor n t k, MCtor m u l) -> n == m && t == u && k == l && mRep f == mRep g; _ -> False }


-- the `case` pushed to the leaves
push :: Tab -> Class -> Re -> Map.Map Int Int -> [(MPat, MExpr)] -> MExpr -> M (Maybe MExpr)
push tab cls re counts bs = go
  where
    go e@(MExpr _ node) =
      case node of
        MIf arms el ->
          do  arms' <- mapM (\(c, b) -> fmap ((,) c) <$> go b) arms
              el' <- go el
              return (MExpr cls <$> (MIf <$> sequence arms' <*> el'))
        MCase s inner ->
          do  inner' <- mapM (\(p, b) -> fmap ((,) p) <$> go b) inner
              return (MExpr cls . MCase s <$> sequence inner')
        MLetVal x v b -> fmap (MExpr cls . MLetVal x v) <$> go b
        MSeq a b -> fmap (MExpr cls . MSeq a) <$> go b
        _ ->
          case (pick bs e, ctorApp e) of
            (Just i, Just (_, _, args)) ->
              do  let (MPat _ pat, body0) = bs !! i
                  let copied = Map.findWithDefault 0 i counts > 1
                  let lifted = any (`Set.member` tLifted tab) (exprRefs body0)
                  case pat of
                    PCtor _ _ ps ->
                      do  -- a copied branch gets fresh names for its pattern variables (a tiny branch binds nothing itself)
                          (ps', ren) <- if copied then freshPats ps else return (ps, Map.empty)
                          let body1 = if Map.null ren then body0 else substitute ren body0
                          let boxed = Map.fromList [ (v, mRep a) | (MPat CRef (PVar v), a) <- zip ps' args, isStruct (mRep a) ]
                          let bind (q@(MPat qc qp), a) acc =
                                case qp of
                                  PVar v | uses v acc > 0 || lifted ->
                                    if qc == mRep a || Map.member v boxed then MExpr (mRep acc) (MLetVal v a acc)
                                    else MExpr (mRep acc) (MCase a [(q, acc)])                 -- the box is opened
                                  PTuple _ -> MExpr (mRep acc) (MCase a [(q, acc)])
                                  _ | atom a -> acc
                                    | otherwise -> MExpr (mRep acc) (MSeq a acc)
                          return (fmap (\body -> foldr bind body (zip ps' args)) (reclass (Map.union boxed (reVars re)) (reRes re) body1))
                    PVar v | not copied -> return (fmap (MExpr cls . MLetVal v e) (reclass (reVars re) (reRes re) body0))
                    PVar _ -> return Nothing
                    _ ->
                      -- a wildcard: the arguments are still evaluated
                      return (fmap (\body -> foldr (\a acc -> if atom a then acc else MExpr (mRep acc) (MSeq a acc)) body args) (reclass (reVars re) (reRes re) body0))
            _ -> return Nothing
    freshPats ps =
      do  (rev, env) <- foldM (\(acc, en) q -> do { (q', en') <- freshPat en q; return (q' : acc, en') }) ([], Map.empty) ps
          return (reverse rev, env)


-- NAMES


fresh :: String -> M String
fresh n =
  do  (k, a, b) <- get
      put (k + 1, a, b)
      return (stem n ++ "@@" ++ show k)
  where
    stem x = case x of { '@' : '@' : _ -> []; c : r -> c : stem r; [] -> [] }


binders :: MExpr -> [String]
binders e =
  (case mNode e of
     MLetVal x _ _ -> [x]
     MCase _ bs -> concatMap (patVars . fst) bs
     MLam ps _ -> map fst ps
     _ -> [])
  ++ concatMap binders (children e)


-- replace variables (no binder of the expression is in the map)
substitute :: Map.Map String MNode -> MExpr -> MExpr
substitute env = go
  where
    go (MExpr c n) =
      MExpr c $ case n of
        MLocal x -> Map.findWithDefault n x env
        MCall f args -> MCall (go f) (map go args)
        MLam ps b -> MLam ps (go b)
        MIf arms el -> MIf [ (go a, go b) | (a, b) <- arms ] (go el)
        MLetVal x v b -> MLetVal x (go v) (go b)
        MSeq a b -> MSeq (go a) (go b)
        MCase s bs -> MCase (go s) [ (p, go b) | (p, b) <- bs ]
        MAccess x f i -> MAccess (go x) f i
        MUpdate x fs -> MUpdate (go x) [ (f, go v) | (f, v) <- fs ]
        MRecord fs -> MRecord [ (f, go v) | (f, v) <- fs ]
        MTuple xs -> MTuple (map go xs)
        MList xs -> MList (map go xs)
        _ -> n


-- a copy of an expression in which every variable it binds has a fresh name; `env` replaces its free variables
freshen :: Map.Map String MNode -> MExpr -> M MExpr
freshen env (MExpr c n) =
  MExpr c <$> case n of
    MLocal x -> return (Map.findWithDefault n x env)
    MCall f args -> MCall <$> go f <*> mapM go args
    MLam ps b -> MLam ps <$> go b
    MIf arms el -> MIf <$> mapM (\(a, b) -> (,) <$> go a <*> go b) arms <*> go el
    MLetVal x v b ->
      do  v' <- go v
          x' <- fresh x
          MLetVal x' v' <$> freshen (Map.insert x (MLocal x') env) b
    MSeq a b -> MSeq <$> go a <*> go b
    MCase s bs ->
      do  s' <- go s
          bs' <- forM bs $ \(p, b) ->
            do  (p', env') <- freshPat env p
                b' <- freshen env' b
                return (p', b')
          return (MCase s' bs')
    MAccess x f i -> (\x' -> MAccess x' f i) <$> go x
    MUpdate x fs -> MUpdate <$> go x <*> mapM (\(f, v) -> (,) f <$> go v) fs
    MRecord fs -> MRecord <$> mapM (\(f, v) -> (,) f <$> go v) fs
    MTuple xs -> MTuple <$> mapM go xs
    MList xs -> MList <$> mapM go xs
    _ -> return n
  where
    go = freshen env


freshPat :: Map.Map String MNode -> MPat -> M (MPat, Map.Map String MNode)
freshPat env (MPat c p) =
  case p of
    PVar v -> do { v' <- fresh v; return (MPat c (PVar v'), Map.insert v (MLocal v') env) }
    PCtor n t ps -> do { (ps', env') <- pats env ps; return (MPat c (PCtor n t ps'), env') }
    PTuple ps -> do { (ps', env') <- pats env ps; return (MPat c (PTuple ps'), env') }
    PCons a b -> do { (a', e1) <- freshPat env a; (b', e2) <- freshPat e1 b; return (MPat c (PCons a' b'), e2) }
    PAlias q v -> do { (q', e1) <- freshPat env q; v' <- fresh v; return (MPat c (PAlias q' v'), Map.insert v (MLocal v') e1) }
    PRecord fs ->
      do  fs' <- forM fs (\(i, v, fc) -> do { v' <- fresh v; return ((i, v', fc), (v, v')) })
          return (MPat c (PRecord (map fst fs')), foldr (\(v, v') -> Map.insert v (MLocal v')) env (map snd fs'))
    _ -> return (MPat c p, env)
  where
    pats e0 ps =
      do  (rev, e') <- foldM (\(acc, e) q -> do { (q', e2) <- freshPat e q; return (q' : acc, e2) }) ([], e0) ps
          return (reverse rev, e')
