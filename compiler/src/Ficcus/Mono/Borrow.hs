{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE PatternGuards #-}
module Ficcus.Mono.Borrow
  ( OwnCtx
  , ownCtx
  , inferBorrow
  , ownedVars
  , viewExpr
  , viewRoot
  )
  where


-- Ficcus, stage (iv) slice S3: borrow inference (docs/STAGE4-PLAN.md, sections 4 and 13).
--
-- Per clone, which reference parameters are *borrowed*: the function only looks at them, the caller keeps the value alive for the
-- whole call and no count is passed. A parameter is OWNED (the function consumes a count) when the body
--
--   * uses it in an owned position: returns it, stores it in a constructor, record, tuple, list or closure, binds it with a `let`,
--     passes it to an owned parameter of a known call, to a closure call or to an owned kernel argument; or
--   * passes it, in a self tail call (a loop), to a borrowed parameter a value that does not stay alive for the whole call: the loop
--     has no "after" in which an owned temporary could be dropped (3.6).
--
-- Everything else is borrowed. Starting from "all borrowed" the inference only ever turns parameters into owned ones, so a plain
-- iteration over all clones reaches the fixed point (the order of the clones does not matter; mutual recursion is covered).
-- A pattern variable that is consumed does NOT make the scrutinee owned (Lean does: it prepares constructor reuse, which is S4).
--
-- `ownedVars` is also the question the Rc pass asks of a case branch: which of the variables the pattern binds are consumed (those
-- get a count of their own at the start of the branch; the others are views into the scrutinee, which stays alive).


import qualified Data.Graph as Graph
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)

import Ficcus.Mono.Class
import Ficcus.Mono.Free
import Ficcus.Mono.Ir
import Ficcus.Mono.Kernel (kernelSig)
import Ficcus.Mono.Layout (objSizeClass)
import Ficcus.Mono.Reuse


data OwnCtx =
  OwnCtx
    { ocClones :: Map.Map CloneId MDef
    , ocCaps :: Map.Map CloneId [(String, Class)]
    }


ownCtx :: Map.Map CloneId [(String, Class)] -> [MDef] -> OwnCtx
ownCtx caps clones = OwnCtx (Map.fromList [ (mdClone d, d) | d <- clones ]) caps


-- | the clones with `mdOwn` inferred; `root` (the `main` value) is left alone
inferBorrow :: Map.Map String UnionShape -> Maybe CloneId -> [MDef] -> [MDef]
inferBorrow unions root clones0 = go (map start clones0)
  where
    recTypes = recursiveTypes unions
    sccs = sccOf clones0
    caps = captures clones0
    -- a call that hands a parameter a value of another class (a struct where a box is expected) makes a fresh box that only an owner drops
    byId = Map.fromList [ (mdClone d, d) | d <- clones0 ]
    mismatched = Set.fromList [ (c, i) | d <- clones0, Just body <- [mdBody d], (c, i) <- mismatches body ]
    mismatches e =
      concatMap mismatches (children e) ++
      (case mNode e of
         MCall h args
           | MGlobal c <- mNode h, Just d <- Map.lookup c byId, mdKind d == Function, length args == length (mdParams d) ->
               [ (c, i) | (i, a, (_, pc)) <- zip3 [0 :: Int ..] args (mdParams d), mRep a /= pc ]
         _ -> [])
    start d = d { mdOwn = [ if refClass c && not (Set.member (mdClone d, i) mismatched) then Borrowed else Owned | (i, (_, c)) <- zip [0 :: Int ..] (mdParams d) ] }
    go cs =
      let ctx = ownCtx caps cs
          cs' = map (step ctx) cs
      in if map mdOwn cs' == map mdOwn cs then cs else go cs'
    step ctx d =
      case mdBody d of
        Just body | mdKind d == Function, Just (mdClone d) /= root ->
          let consumed = Set.unions [ownedVars ctx body, tailBad ctx d, if projRule then projOwned ctx d else Set.empty, if reuseRule then reuseOwned ctx d else Set.empty,
                                       if hybridRule then hybridOwned unions recTypes sccs ctx d else Set.empty]
              now = [ if o == Owned || Set.member n consumed then Owned else Borrowed | ((n, _), o) <- zip (mdParams d) (paramOwns d) ]
          in d { mdOwn = now }
        _ -> d


-- OWNED POSITIONS


-- | the variables an expression uses in an owned position (its value is consumed), by the conventions of the Rc pass
ownedVars :: OwnCtx -> MExpr -> Set.Set String
ownedVars ctx = owned
  where
    owned e =
      case mNode e of
        MLit _ -> Set.empty
        MLocal n -> if refClass (mRep e) then Set.singleton n else Set.empty
        MGlobal c -> capturedRefs c
        MKernel _ _ -> Set.empty
        MCtor _ _ _ -> Set.empty
        MCall h args -> call h args
        MLam _ b -> owned b
        MIf bs f -> Set.unions (owned f : [ Set.union (owned c) (owned b) | (c, b) <- bs ])
        MLetVal _ v b -> Set.union (owned v) (owned b)
        MSeq a b -> Set.union (owned a) (owned b)
        MCase s bs -> Set.unions ((case mNode s of { MLocal _ -> Set.empty; _ -> owned s }) : map (owned . snd) bs)
        MAccess r _ _ -> borrowed r
        MUpdate r fs -> Set.unions (owned r : map (owned . snd) fs)
        MRecord fs -> Set.unions (map (owned . snd) fs)
        MTuple xs -> Set.unions (map owned xs)
        MList xs -> Set.unions (map owned xs)
        MDup _ b -> owned b
        MDrop _ b -> owned b
        MOwn b -> borrowed b
        MUnpack _ _ _ b -> owned b
        MSpec _ _ _ _ b -> owned b
        MReuse _ b -> owned b
        MFreeTok _ b -> owned b
    -- an argument that is only looked at: a variable or a projection of one is used as it is, anything else is evaluated into a
    -- temporary that the call drops afterwards
    borrowed a = if viewExpr (ocClones ctx) a then Set.empty else owned a
    capturedRefs c =
      case Map.lookup c (ocClones ctx) of
        Just d | mdKind d == Function -> Set.fromList [ n | (n, cc) <- Map.findWithDefault [] c (ocCaps ctx), refClass cc ]
        _ -> Set.empty
    call h args =
      case mNode h of
        MKernel name _
          | name `elem` ["elm/core:Basics.and", "elm/core:Basics.or"] -> Set.unions (map owned args)
          | Just sigText <- kernelSig name (keyOf h), length sigText == length args ->
              Set.unions [ if l == 'o' && refClass (mRep a) then owned a else borrowed a | (l, a) <- zip sigText args ]
          | otherwise -> Set.unions (map owned args)
        MCtor _ _ _ -> Set.unions (map owned args)
        MGlobal c
          | Just d <- Map.lookup c (ocClones ctx), mdKind d == Function, length args == length (mdParams d) ->
              Set.unions [ if o == Borrowed && refClass (mRep a) && mRep a == pc then borrowed a else owned a
                         | (a, o, (_, pc)) <- zip3 args (paramOwns d) (mdParams d) ]
        _ -> Set.unions (headUse h : map owned args)
    headUse h =
      case mNode h of
        MGlobal c | Just d <- Map.lookup c (ocClones ctx), mdKind d == Value -> Set.empty
                  | null (Map.findWithDefault [] c (ocCaps ctx)) -> Set.empty
        _ -> if refClass (mRep h) then borrowed h else Set.empty
    keyOf h = case mNode h of { MKernel _ k -> k; _ -> Key [] }


-- | an expression that only reads a variable or something static: usable in a borrowed position without a temporary
viewExpr :: Map.Map CloneId MDef -> MExpr -> Bool
viewExpr clones a =
  case mNode a of
    MLocal _ -> True
    MAccess r _ _ -> viewExpr clones r
    MLit _ -> True
    MCtor _ _ _ -> True
    MGlobal c -> maybe False ((== Value) . mdKind) (Map.lookup c clones)
    _ -> False


-- | the variable a view reads (a variable, or the record a field is read from)
viewRoot :: MExpr -> Maybe String
viewRoot e =
  case mNode e of
    MLocal n -> Just n
    MAccess r _ _ -> viewRoot r
    _ -> Nothing


-- TAIL CALLS


-- | the parameters of a clone that must be owned because a self tail call hands a borrowed parameter a value that is not alive for
-- the whole call
tailBad :: OwnCtx -> MDef -> Set.Set String
tailBad ctx d =
  case mdBody d of
    Nothing -> Set.empty
    Just body -> go True env0 body
  where
    params = mdParams d
    env0 = Map.fromList [ (n, o == Borrowed) | ((n, _), o) <- zip params (paramOwns d) ]     -- stable: alive for the whole call
    stable env n = Map.findWithDefault True n env                                              -- a captured variable is borrowed too
    go tl env e =
      case mNode e of
        MIf bs f -> Set.unions (go tl env f : [ go tl env b | (_, b) <- bs ])
        MLetVal n _ b -> go tl (Map.insert n False env) b
        MSeq _ b -> go tl env b
        MDup _ b -> go tl env b
        MDrop _ b -> go tl env b
        MSpec _ _ _ _ b -> go tl env b
        MFreeTok _ b -> go tl env b
        MCase s bs ->
          Set.unions
            [ go tl (foldr (\(v, _) m -> Map.insert v viaScrutinee m) env (patBinders p)) b
            | (p, b) <- bs ]
          where viaScrutinee = case mNode s of { MLocal n -> stable env n; _ -> False }
        MCall h args
          | MGlobal c <- mNode h, c == mdClone d, length args == length params, tl ->
              Set.fromList [ n | (((n, pc), o), a) <- zip (zip params (paramOwns d)) args, o == Borrowed, not (stableArg env pc a) ]
          | MKernel name _ <- mNode h, name `elem` ["elm/core:Basics.and", "elm/core:Basics.or"], [_, b] <- args -> go tl env b
        _ -> Set.empty
    stableArg env pc a =
      not (refClass pc) || (mRep a == pc && stableExpr env a)
    stableExpr env a =
      case mNode a of
        MLocal n -> stable env n
        MAccess r _ _ -> stableExpr env r
        MLit _ -> True
        MCtor _ _ _ -> True
        MGlobal c -> maybe False ((== Value) . mdKind) (Map.lookup c (ocClones ctx))
        _ -> False


{-# NOINLINE reuseRule #-}
-- | EXPERIMENT (S4): a parameter is owned when a case on it is a reuse candidate (`FICCUS_BORROW_REUSE=1`)
reuseRule :: Bool
reuseRule = unsafePerformIO (fmap (== Just "1") (lookupEnv "FICCUS_BORROW_REUSE"))


-- | the parameters of which a case in tail position is a candidate for constructor reuse: the pattern is one constructor (or `::`) with
-- variable arguments, the branch does not use the parameter again and builds an object of the size class of the matched cell
reuseOwned :: OwnCtx -> MDef -> Set.Set String
reuseOwned ctx d =
  case mdBody d of
    Nothing -> Set.empty
    Just body ->
      Set.fromList
        [ n
        | (n, p, b) <- reuseCandidates body, n `elem` map fst (mdParams d)
        , Just cell <- [cellOfPat p], Just k <- [objSizeClass (cellFields cell)]
        , Map.notMember n (freeVars (ocCaps ctx) b)
        , Just _ <- [placeToken "tok" k b] ]


{-# NOINLINE hybridRule #-}
-- | EXPERIMENT (S4b): the projection rule only for recursion over recursive data (`FICCUS_BORROW_HYBRID=1`)
hybridRule :: Bool
hybridRule = unsafePerformIO (fmap (== Just "1") (lookupEnv "FICCUS_BORROW_HYBRID"))


-- | the custom types that contain themselves (directly, through another custom type, or inside a list, tuple or record field)
recursiveTypes :: Map.Map String UnionShape -> Set.Set String
recursiveTypes unions =
  Set.fromList (concat [ ns | Graph.CyclicSCC ns <- Graph.stronglyConnComp [ (n, n, refsOf u) | (n, u) <- Map.toList unions ] ])
  where
    refsOf u = concat [ concatMap tyRefs fs | (_, _, fs) <- usCtors u ]
    tyRefs t =
      case t of
        TyCon n args -> n : concatMap tyRefs args
        TyFun a b -> tyRefs a ++ tyRefs b
        TyRecord fs -> concatMap (tyRefs . snd) fs
        TyTuple ts -> concatMap tyRefs ts
        TyUnit -> []


-- | for each clone that can reach itself through calls, a number that identifies its group of mutually recursive clones
sccOf :: [MDef] -> Map.Map CloneId Int
sccOf clones =
  Map.fromList (concat [ [ (c, i) | c <- cs ] | (i, Graph.CyclicSCC cs) <- zip [0 :: Int ..] comps ])
  where
    comps = Graph.stronglyConnComp [ (mdClone d, mdClone d, maybe [] exprRefs (mdBody d)) | d <- clones ]


-- | S4b, the hybrid rule: the parameters that Lean's projection rule would own (a pattern variable taken from them is consumed), but
-- only when (1) the parameter is matched against a recursive data type (a list pattern, or a constructor of a custom type that
-- contains itself) and (2) the parameter, or a pattern variable taken from it, is an argument of a call of a recursive function
-- (itself: it recurses over the value; or another one: it hands the parts to a recursion, as `replaceMin` does with `siftdown`).
-- A function that passes the whole parameter on gets it owned by the ordinary rule (an argument of an owned parameter). Everything else (numeric loops, arrays, records
-- and tuples, a single match in a function that does not recurse) stays borrowed.
hybridOwned :: Map.Map String UnionShape -> Set.Set String -> Map.Map CloneId Int -> OwnCtx -> MDef -> Set.Set String
hybridOwned unions recTypes sccs ctx d =
  case mdBody d of
    Just body ->
      let params = Set.fromList (map fst (mdParams d))
          rootOf = roots (Map.fromList [ (n, n) | n <- Set.toList params ]) body
          recData = Set.fromList [ n | (n, p) <- matches body, Set.member n params, recPat p ]
          toRec = Set.fromList [ q | args <- recCalls body, a <- args, v <- Map.keys (freeVars (ocCaps ctx) a), Just q <- [Map.lookup v rootOf] ]
      in Set.intersection (projOwned ctx d) (Set.intersection recData toRec)
    _ -> Set.empty
  where
    -- every pattern variable taken (through any number of matches) from a parameter, with that parameter
    roots env e =
      case mNode e of
        MCase s bs | MLocal n <- mNode s, Just q <- Map.lookup n env ->
          Map.unions (env : roots env s : [ roots (foldr (\(v, _) m -> Map.insert v q m) env (patBinders p)) b | (p, b) <- bs ])
        _ -> Map.unions (env : map (roots env) (children e))
    matches e =
      (case mNode e of
         MCase s bs | MLocal n <- mNode s -> [ (n, p) | (p, _) <- bs ]
         _ -> [])
      ++ concatMap matches (children e)
    recPat (MPat _ node) =
      case node of
        PCons _ _ -> True
        PNil -> True
        PAlias q _ -> recPat q
        PCtor name tag ps ->
          or [ Set.member t recTypes | (t, u) <- Map.toList unions, (n, k, fs) <- usCtors u, n == name, k == tag, length fs == length ps ]
        _ -> False
    -- the calls of recursive functions (this one included)
    recCalls e =
      (case mNode e of
         MCall h args | MGlobal c <- mNode h, Map.member c sccs -> [args]
         _ -> [])
      ++ concatMap recCalls (children e)


{-# NOINLINE projRule #-}
projRule :: Bool
projRule = unsafePerformIO (fmap (== Just "1") (lookupEnv "FICCUS_BORROW_PROJ"))


-- | EXPERIMENT (Lean's rule): a parameter of which a consumed pattern variable is a projection is owned too
projOwned :: OwnCtx -> MDef -> Set.Set String
projOwned ctx d =
  case mdBody d of
    Nothing -> Set.empty
    Just body -> go (Map.fromList [ (n, n) | (n, _) <- mdParams d ]) body
  where
    go env e =
      let here =
            case mNode e of
              MCase s bs
                | MLocal n <- mNode s, Just q <- Map.lookup n env ->
                    Set.unions [ Set.intersection (Set.fromList (map fst (patBinders p))) (ownedVars ctx b) `seq`
                                 (if Set.null (Set.intersection (Set.fromList (map fst (patBinders p))) (ownedVars ctx b)) then Set.empty else Set.singleton q)
                               | (p, b) <- bs ]
              _ -> Set.empty
          env' = case mNode e of
                   MCase s _ | MLocal n <- mNode s, Just q <- Map.lookup n env -> \ps -> foldr (\v m -> Map.insert v q m) env ps
                   _ -> const env
          below =
            case mNode e of
              MCase s bs -> go env s : [ go (env' (map fst (patBinders p))) b | (p, b) <- bs ]
              _ -> map (go env) (children e)
      in Set.unions (here : below)

