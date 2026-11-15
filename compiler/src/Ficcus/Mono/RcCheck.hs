{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE FlexibleContexts, PatternGuards #-}
module Ficcus.Mono.RcCheck
  ( rcCheck
  )
  where


-- Ficcus, stage (iv) slice S2: the independent static checker of the Rc pass (docs/STAGE4-PLAN.md, section 10, item 1).
--
-- It knows nothing of how the pass decides: it takes the annotated Mono (with `MDup`, `MDrop`, `MOwn`) and walks every path of
-- every clone in evaluation order, holding for each variable the number of counts the scope owns:
--
--   * a use in an OWNED position (an argument of an owned parameter, a constructor field, the returned value, a captured variable
--     of a closure, `MDrop`) takes one of the counts: it is an error when there is none (use after the last consumption);
--   * a use in a BORROWED position (a borrowed kernel argument, the scrutinee of a case, the record of a field access, a captured
--     variable passed to a lifted function) needs the variable to be readable: it has a count, or it is a view (a pattern variable, a
--     captured parameter) of something that is still readable;
--   * `MDup` adds a count, `MOwn` makes an owned value of something that is only looked at;
--   * a branch must leave every variable with the same number of counts as the other branches (an owned variable consumed on one
--     path and not on the other is a leak or a double free), a `let` variable and a pattern variable must have no counts left at
--     the end of their scope, and a function must end with none of its owned parameters left;
--   * the expressions that have no count of their own (a bare string literal, a global, a nullary constructor, a static closure)
--     must not be in an owned position: the pass wraps them in `MOwn`.
--
-- The kernel signatures come from Ficcus.Mono.Kernel (the same table the pass uses: the checker checks the use of the table, not
-- the table).


import Control.Monad (forM_, unless, when, zipWithM_)
import Control.Monad.State.Strict (StateT(..), evalStateT, get, gets, modify')
import qualified Data.List as List
import qualified Data.Map.Strict as Map

import Ficcus.Mono.Borrow (viewExpr, viewRoot)
import Ficcus.Mono.Class
import Ficcus.Mono.Free
import Ficcus.Mono.Ir
import Ficcus.Mono.Kernel (applyOwnKernel, kernelResultBorrowed, kernelSig, isTakeKernel, setOfTake)
import Ficcus.Mono.Layout (leavesOf, objSizeClass)
import Ficcus.Mono.Reuse


data V =
  V
    { vOwned :: Bool                    -- a variable with a count of its own (a parameter, a let, a dup'd view), not a view
    , vCount :: Int
    , vRoot :: Maybe String             -- the variable a view looks into
    }


type Scope = Map.Map String V


data Cx =
  Cx
    { cxScope :: Scope
    , cxClones :: Map.Map CloneId MDef
    , cxCaps :: Map.Map CloneId [(String, Class)]
    , cxTokens :: Map.Map String (Maybe Int)     -- the reuse tokens in scope (S4) and the size class of their cell
    , cxCells :: Map.Map String Cell             -- the variables that an enclosing case branch matched against one constructor (S4, S6)
    }


type CK a = StateT Cx (Either String) a


-- | the violations of the counting rules in the program, as messages (empty: the program is correct)
rcCheck :: MProgram -> [String]
rcCheck program =
  let clones = mpClones program
      caps = captures clones
      byId = Map.fromList [ (mdClone d, d) | d <- clones ]
  in [ msg
     | d <- clones, Just (mdClone d) /= mpMain program, Just body <- [mdBody d]
     , Left err <- [evalStateT (checkDef d caps body) (Cx Map.empty byId caps Map.empty Map.empty)]
     , let msg = "rc check: " ++ mdName d ++ ": " ++ err ]
     ++ [ "rc check: " ++ mdName d ++ ": " ++ err
        | d <- clones, Just (mdClone d) /= mpMain program, Just body <- [mdBody d], err <- tailCheck byId d body ]
     ++ [ "rc check: " ++ mdName d ++ ": " ++ err
        | d <- clones, Just (mdClone d) /= mpMain program, Just body <- [mdBody d], err <- takeCheck caps body ]


bad :: String -> CK a
bad msg = StateT (\_ -> Left msg)


checkDef :: MDef -> Map.Map CloneId [(String, Class)] -> MExpr -> CK ()
checkDef d caps body =
  do  let capVars = [ n | (n, c) <- Map.findWithDefault [] (mdClone d) caps, refClass c ]
      let params = [ (n, o) | ((n, c), o) <- zip (mdParams d) (paramOwns d), refClass c ]
      -- an owned parameter has one count; a borrowed one is readable for the whole call and has none
      modify' (\s -> s { cxScope = Map.fromList ([ (n, if o == Owned then V True 1 Nothing else V False 0 Nothing) | (n, o) <- params ]
                                                 -- a captured variable is readable for the whole call; in a twin (Ficcus.Mono.Twin) it is owned
                                                 ++ [ (n, if mdCapsOwned d then V True 1 Nothing else V False 0 Nothing) | n <- capVars ]) })
      owned body
      sc <- gets cxScope
      forM_ (Map.toList sc) $ \(n, v) ->
        when (vCount v /= 0) (bad ("variable " ++ n ++ " has " ++ show (vCount v) ++ " count(s) left at the end of the function"))


-- | the reference leaves of a class
refLeaves :: Class -> [Class]
refLeaves c = [ l | l@CRef <- leavesOf c ]


-- VARIABLES

readable :: String -> CK Bool
readable n =
  do  sc <- gets cxScope
      return (isReadable sc n)


isReadable :: Scope -> String -> Bool
isReadable sc n =
  case Map.lookup n sc of
    Nothing -> False
    Just v
      | vCount v > 0 -> True
      | vOwned v -> False
      | otherwise -> maybe True (isReadable sc) (vRoot v)


-- a use that reads the variable
borrow :: String -> CK ()
borrow n =
  do  ok <- readable n
      unless ok (bad ("variable " ++ n ++ " is read when it is not alive (no count and no live owner)"))


-- a use that takes a count
consume :: String -> CK ()
consume n =
  do  sc <- gets cxScope
      case Map.lookup n sc of
        Nothing -> bad ("variable " ++ n ++ " is consumed but is not in scope")
        Just v
          | vCount v <= 0 -> bad ("variable " ++ n ++ " is consumed when it has no count (used after its last use, or a view used as owned)")
          | otherwise -> modify' (\s -> s { cxScope = Map.insert n v { vCount = vCount v - 1 } sc })


addCount :: String -> CK ()
addCount n =
  do  borrow n
      modify' (\s -> s { cxScope = Map.adjust (\v -> v { vCount = vCount v + 1 }) n (cxScope s) })


-- a variable of this class with one count, for the scope of `body`; it must have none left at the end
withOwned :: String -> Class -> CK a -> CK a
withOwned n c body =
  if not (refClass c) then body
  else
    do  old <- gets (Map.lookup n . cxScope)
        modify' (\s -> s { cxScope = Map.insert n (V True 1 Nothing) (cxScope s) })
        r <- body
        v <- gets (Map.lookup n . cxScope)
        case v of
          Just x | vCount x /= 0 -> bad ("variable " ++ n ++ " has " ++ show (vCount x) ++ " count(s) left at the end of its scope")
          _ -> return ()
        modify' (\s -> s { cxScope = maybe (Map.delete n (cxScope s)) (\o -> Map.insert n o (cxScope s)) old })
        return r


-- EXPRESSIONS

-- | an expression in an owned position: it yields a count
owned :: MExpr -> CK ()
owned e =
  let cls = mRep e in
  case mNode e of
    MLit (LString _) -> bad "a string literal without a count in an owned position (not wrapped in Own)"
    MLit _ -> return ()
    MLocal n -> when (refClass cls) (consume n)
    MGlobal c ->
      do  cx <- get
          case Map.lookup c (cxClones cx) of
            Nothing -> bad "an unknown clone"
            Just d
              | mdKind d == Value -> when (refClass (mdResult d) || refClass cls) (bad "a global value without a count in an owned position (not wrapped in Own)")
              | null (Map.findWithDefault [] c (cxCaps cx)) -> bad "a static closure without a count in an owned position (not wrapped in Own)"
              | otherwise -> forM_ [ n | (n, cc) <- Map.findWithDefault [] c (cxCaps cx), refClass cc ] consume       -- the closure takes a count on each captured reference
    MKernel _ _ -> return ()
    MCtor _ _ _ -> when (refClass cls) (bad "a nullary constructor without a count in an owned position (not wrapped in Own)")
    MCall h args -> call e h args
    MLam _ _ -> bad "a lambda"
    MIf bs final -> ifChain bs final
    MLetVal n v b ->
      do  owned v
          withOwned n (mRep v) (owned b)
    MSeq a b ->
      do  when (refClass (mRep a)) (bad "the value of a sequence is a reference that is never consumed")
          owned a
          owned b
    MCase s bs -> caseOf s bs
    MAccess r _ _ ->
      do  when (refClass cls) (bad "a field access that yields a reference without a count (not wrapped in Own)")
          viewRecord r
    MUpdate _ _ -> bad "a record update"
    MRecord fs -> mapM_ (owned . snd) fs
    MTuple xs -> mapM_ owned xs
    MList xs -> mapM_ owned xs
    MDup vs b ->
      do  forM_ vs (\(n, c) -> when (refClass c) (addCount n))
          owned b
    MDrop vs b ->
      do  forM_ vs (\(n, c) -> when (refClass c) (consume n))
          owned b
    MOwn b -> view b
    MSpec s fcs bs mt body -> specOf s fcs bs mt body
    MReuse t x ->
      do  tokens <- gets cxTokens
          case Map.lookup t tokens of
            Nothing -> bad ("the reuse token " ++ t ++ " is not in scope")
            Just k ->
              case appCell x of
                Just cs | k /= Nothing, objSizeClass cs == k -> return ()
                _ -> bad ("the reuse token " ++ t ++ " is used by something that is not a constructor application of the size class of its cell")
          owned x
          consume t
    MFreeTok t b ->
      do  tokens <- gets cxTokens
          unless (Map.member t tokens) (bad ("the reuse token " ++ t ++ " is not in scope"))
          consume t
          owned b
    MUnpack s c bs b ->
      do  let nleaves = length (refLeaves c)
          let taken = concat [ ix | (_, _, ix) <- bs ]
          when (length taken /= length (List.nub taken) || any (\k -> k < 0 || k >= nleaves) taken)
            (bad "a component of a struct is taken twice, or does not exist")
          forM_ bs (\(v, vc, ix) -> when (length ix /= length (refLeaves vc)) (bad ("the pattern variable " ++ v ++ " takes the wrong number of components")))
          forM_ bs (\(v, vc, _) -> when (refClass vc) (modify' (\st -> st { cxScope = Map.adjust (\x -> x { vCount = vCount x + 1 }) v (cxScope st) })))
          consume s
          owned b


-- | the record of a field access: a struct without references is any expression (`(mk x).b`, `(let q = .. in q).a`: there is
-- nothing to keep alive), one with references is looked at
viewRecord :: MExpr -> CK ()
viewRecord r = if refClass (mRep r) then view r else owned r


-- | an expression that only looks at something that stays alive (the argument of `MOwn`, a borrowed argument)
view :: MExpr -> CK ()
view e =
  case mNode e of
    MLit _ -> return ()
    MLocal n -> when (refClass (mRep e)) (borrow n)
    MGlobal _ -> return ()
    MKernel _ _ -> return ()
    MCtor _ _ _ -> return ()
    MAccess r _ _ -> viewRecord r
    MCall (MExpr _ (MKernel name _)) args | kernelResultBorrowed name -> kernelCallArgs name args
    _ -> bad "an expression in a position that only looks at a value (a borrowed argument must be a variable, a literal or a global)"


call :: MExpr -> MExpr -> [MExpr] -> CK ()
call e h args =
  case mNode h of
    MKernel name _
      | name == applyOwnKernel ->                    -- S6: a call of a function value that consumes the function and every argument
          do  when (null args) (bad "an owning call without a function")
              mapM_ owned args
    MKernel name key ->
      do  when (kernelResultBorrowed name && refClass (mRep e)) (bad "a kernel result without a count in an owned position (not wrapped in Own)")
          unless (name `elem` ["elm/core:Basics.and", "elm/core:Basics.or"]) (kernelCallArgs' name key args)
          when (name `elem` ["elm/core:Basics.and", "elm/core:Basics.or"]) (bad "&& or || reached the checker (the pass makes them an if)")
    MCtor _ _ _ -> mapM_ owned args
    MGlobal c ->
      do  cx <- get
          case Map.lookup c (cxClones cx) of
            Just d | mdKind d == Function, length args == length (mdParams d) ->
              do  forM_ (zip3 args (paramOwns d) (mdParams d)) $ \(a, o, (_, pc)) ->
                    if o == Borrowed && refClass (mRep a) && mRep a == pc then view a else owned a     -- another class: the generator converts, an owned value
                  -- the borrowed variables must still be alive when the call happens (after the owned arguments have been consumed)
                  forM_ [ n | (a, o, (_, pc)) <- zip3 args (paramOwns d) (mdParams d), o == Borrowed, refClass (mRep a), mRep a == pc, Just n <- [viewRoot a] ] borrow
                  forM_ [ n | (n, cc) <- Map.findWithDefault [] c (cxCaps cx), refClass cc ] borrow     -- the caller passes its variables, borrowed
            _ -> apply
    _ -> apply
  where
    apply =
      do  case mNode h of
            MLocal _ -> view h
            MGlobal _ -> view h
            _ -> bad "the function of a call of a function value is not a variable or a global"
          mapM_ owned args


kernelCallArgs :: String -> [MExpr] -> CK ()
kernelCallArgs name args = kernelCallArgs' name (Key []) args


kernelCallArgs' :: String -> Key -> [MExpr] -> CK ()
kernelCallArgs' name key args =
  case kernelSig name key of
    Nothing -> bad ("the kernel " ++ name ++ " has no signature")
    Just sig
      | length sig /= length args -> bad ("the kernel " ++ name ++ " has a signature of the wrong length")
      | otherwise ->
          do  zipWithM_ (\l a -> if not (refClass (mRep a)) then owned a else if l == 'o' then owned a else view a) sig args
              -- the borrowed variables must still be alive when the call happens (after the owned arguments have been consumed)
              forM_ [ n | (l, MExpr c (MLocal n)) <- zip sig args, l /= 'o', refClass c ] borrow


ifChain :: [(MExpr, MExpr)] -> MExpr -> CK ()
ifChain [] final = owned final
ifChain ((c, b) : rest) final =
  do  owned c
      s0 <- gets cxScope
      owned b
      s1 <- gets cxScope
      modify' (\s -> s { cxScope = s0 })
      ifChain rest final
      s2 <- gets cxScope
      agree s1 s2
      -- s2 stays as the state after the whole if


-- | two paths must leave every variable with the same number of counts
agree :: Scope -> Scope -> CK ()
agree a b =
  forM_ (Map.toList a) $ \(n, v) ->
    case Map.lookup n b of
      Just w | vCount w /= vCount v -> bad ("variable " ++ n ++ " has " ++ show (vCount v) ++ " count(s) after one branch and " ++ show (vCount w) ++ " after another")
      _ -> return ()


caseOf :: MExpr -> [(MPat, MExpr)] -> CK ()
caseOf s bs =
  do  case mNode s of
        MLocal n | refClass (mRep s) -> borrow n
        _ | refClass (mRep s) -> bad "the scrutinee of a case is not a variable"
        _ -> owned s
      let root = case mNode s of { MLocal n -> Just n; _ -> Nothing }
      s0 <- gets cxScope
      results <-
        mapM (\(p, b) ->
                do  modify' (\st -> st { cxScope = s0 })
                    let binders = [ n | (n, c) <- patBinders p, refClass c ]
                    forM_ binders (\n -> modify' (\st -> st { cxScope = Map.insert n (V False 0 root) (cxScope st) }))
                    branchBody root p b
                    forM_ binders $ \n ->
                      do  v <- gets (Map.lookup n . cxScope)
                          case v of
                            Just x | vCount x /= 0 -> bad ("pattern variable " ++ n ++ " has " ++ show (vCount x) ++ " count(s) left at the end of its branch")
                            _ -> return ()
                    modify' (\st -> st { cxScope = foldr Map.delete (cxScope st) binders })
                    gets cxScope)
             bs
      case results of
        [] -> return ()
        r : rest ->
          do  mapM_ (agree r) rest
              put' r
  where
    put' sc = modify' (\st -> st { cxScope = sc })


-- | the body of a case branch; while it is checked, the scrutinee variable is known to be an object of the pattern's constructor
branchBody :: Maybe String -> MPat -> MExpr -> CK ()
branchBody root p b =
  case root of
    Nothing -> owned b
    Just r ->
      do  old <- gets cxCells
          modify' (\st -> st { cxCells = maybe (Map.delete r old) (\cell -> Map.insert r cell old) (cellOfPat p) })
          owned b
          modify' (\st -> st { cxCells = old })


-- | a drop specialization (S4; S6: anywhere inside the branch of the case that matched the variable, where the variable dies): the
-- variable is consumed, each listed pattern variable gets a count, a token is used or freed exactly once
specOf :: String -> [Class] -> [(String, Class, Int)] -> Maybe String -> MExpr -> CK ()
specOf s fcs bs mt body =
      do  cells <- gets cxCells
          cell <- maybe (bad ("a drop specialization of " ++ s ++ ", which is not the scrutinee of an enclosing case with a constructor pattern of variables")) return (Map.lookup s cells)
          when (fcs /= cellFields cell) (bad "a drop specialization with a different object layout than its pattern")
          forM_ bs $ \(v, c, i) ->
            unless ((i, v, c) `elem` cellVars cell && i < length fcs && fcs !! i == c && refClass c)
              (bad ("the specialized variable " ++ v ++ " is not a reference field of the pattern"))
          when (length (List.nub [ i | (_, _, i) <- bs ]) /= length bs) (bad "a field of a specialized cell is taken twice")
          consume s
          forM_ bs (\(v, _, _) -> modify' (\st -> st { cxScope = Map.adjust (\x -> x { vCount = vCount x + 1 }) v (cxScope st) }))
          case mt of
            Nothing -> owned body
            Just t ->
              do  modify' (\st -> st { cxScope = Map.insert t (V True 1 Nothing) (cxScope st), cxTokens = Map.insert t (objSizeClass fcs) (cxTokens st) })
                  owned body
                  v <- gets (Map.lookup t . cxScope)
                  case v of
                    Just x | vCount x /= 0 -> bad ("the reuse token " ++ t ++ " has " ++ show (vCount x) ++ " count(s) left at the end of its branch (never used or freed)")
                    _ -> return ()
                  modify' (\st -> st { cxScope = Map.delete t (cxScope st), cxTokens = Map.delete t (cxTokens st) })


-- TAIL CALLS (STAGE4-PLAN 3.6, 13): a self tail call is a loop, which has no "after" in which something could be dropped, so a borrowed
-- parameter may only be given a value that stays alive for the whole call: a borrowed parameter, a captured variable, a field or a
-- pattern variable of those (not counted by the branch), a static value.

tailCheck :: Map.Map CloneId MDef -> MDef -> MExpr -> [String]
tailCheck clones d = go (Map.fromList [ (n, o == Borrowed) | ((n, _), o) <- zip params (paramOwns d) ])
  where
    params = mdParams d
    stable env n = Map.findWithDefault True n env                              -- a variable that is not bound here is captured: borrowed
    go env e =
      case mNode e of
        MIf bs f -> concat (go env f : [ go env b | (_, b) <- bs ])
        MLetVal n _ b -> go (Map.insert n False env) b
        MSeq _ b -> go env b
        MDup _ b -> go env b
        MDrop _ b -> go env b
        MUnpack _ _ _ b -> go env b
        MFreeTok _ b -> go env b
        MSpec _ _ _ _ b -> go env b
        MCase s bs ->
          concat [ go (foldr (\(v, _) m -> Map.insert v (viaScrutinee s env && not (counted v b)) m) env (patBinders p)) b | (p, b) <- bs ]
        MCall h args
          | MGlobal c <- mNode h, c == mdClone d, length args == length params ->
              [ "a self tail call gives the borrowed parameter " ++ n ++ " a value that is not alive for the whole call"
              | (((n, pc), o), a) <- zip (zip params (paramOwns d)) args, o == Borrowed, refClass pc, not (mRep a == pc && stableExpr env a) ]
        _ -> []
    viaScrutinee s env = case mNode s of { MLocal n -> stable env n; _ -> False }
    counted v b = case mNode b of { MDup vs _ -> v `elem` map fst vs; MSpec _ _ bs _ _ -> v `elem` [ n | (n, _, _) <- bs ]; _ -> False }
    stableExpr env a =
      case mNode a of
        MLocal n -> stable env n
        MAccess r _ _ -> stableExpr env r
        MLit _ -> True
        MCtor _ _ _ -> True
        MGlobal c -> viewExpr clones a && maybe False ((== Value) . mdKind) (Map.lookup c clones)
        _ -> False


-- TAKE (S6, docs/STAGE4-S6.md): `unsafeTake i a` moves the element out of a unique array and leaves a placeholder at `i`. Nothing may
-- see the placeholder: the take must be the value of a `let`, `a` and `i` variables (or `i` a literal), and in the body of the `let`
-- the array `a` may only be dropped, or be the array of `unsafeSet i _ a` with the same index and a stored value that does not use `a`.
-- Any other occurrence (a read, a dup, an argument, a capture by a closure or a lifted function) is an error.

takeCheck :: Map.Map CloneId [(String, Class)] -> MExpr -> [String]
takeCheck caps = go
  where
    go e =
      case mNode e of
        MLetVal _ v b
          | Just (setName, i, a) <- takeOf v ->
              (case (mNode i, mNode a) of
                 (_, MLocal t) | atom i -> [ "after the take of an element of " ++ t ++ ": " ++ why | why <- seen setName t i b ]
                 _ -> ["a take whose array is not a variable, or whose index is not a variable or a literal"])
              ++ go b
        MCall h _ | MKernel name _ <- mNode h, isTakeKernel name -> ["a take that is not the value of a let"]
        MKernel name _ | isTakeKernel name -> ["a take that is not called"]
        _ -> concatMap go (children e)
    takeOf v = case mNode v of
      MCall h [i, a] | MKernel name _ <- mNode h, Just setName <- setOfTake name -> Just (setName, i, a)
      _ -> Nothing
    atom i = case mNode i of { MLocal _ -> True; MLit _ -> True; _ -> False }
    sameAtom i j = case (mNode i, mNode j) of { (MLocal x, MLocal y) -> x == y; (MLit x, MLit y) -> x == y; _ -> False }
    -- the occurrences of `t` in `e` that could see the placeholder
    seen :: String -> String -> MExpr -> MExpr -> [String]
    seen setName t i e =
      case mNode e of
        MLocal n -> [ "the array is read" | n == t ]
        MGlobal c -> [ "the array is captured" | t `elem` map fst (Map.findWithDefault [] c caps) ]
        MCall h [j, x, a]
          | MKernel name _ <- mNode h, name == setName, MLocal n <- mNode a, n == t ->
              [ "the array is updated at another index" | not (sameAtom i j) ] ++ seen setName t i j ++ seen setName t i x
        MDup vs b -> [ "the array is dup'd" | t `elem` map fst vs ] ++ seen setName t i b
        MDrop _ b -> seen setName t i b                                         -- a drop does not look at the elements
        MUnpack s _ bs b -> [ "the array is unpacked" | s == t || t `elem` [ v | (v, _, _) <- bs ] ] ++ seen setName t i b
        MSpec s _ bs _ b -> [ "the array is specialized" | s == t || t `elem` [ v | (v, _, _) <- bs ] ] ++ seen setName t i b
        _ -> concatMap (seen setName t i) (children e)
