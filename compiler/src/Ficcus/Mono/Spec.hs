{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE PatternGuards #-}
module Ficcus.Mono.Spec
  ( specialize
  , keyLimit
  , limitMessage
  , classOfM
  , boxed
  )
  where


-- Ficcus, stage (iii) slice 1: the specializer (docs/STAGE3-PLAN.md sections 1 to 3).
--
-- Starting from `main`, a work list of clones (definition, key) is processed. The body of a clone is
-- walked with the Canonical tree and the recorded types of its module; at every use of a name the
-- scheme of the callee is matched against the type at the use (`matchT`, the substitution of the dump),
-- composed with the environment of the current clone, and turned into a key for the callee:
--
--   number, comparable, compappend, equatable / printed (marks)  -> the exact type (ByType)
--   appendable                                                    -> string or list of an element class (ByApp)
--   any other                                                     -> the class of the instance (ByClass)
--   row                                                           -> not yet (slice 5)
--
-- Local functions are lifted: each (definition, owner clone, key) is a clone of its own; the captured
-- variables are found by `Generate.C`. Kernel callees (Ficcus.Mono.Kernel) stay `MKernel`.
-- Supported in this slice: the monomorphic subset of fib, `Platform.worker` with its `init` lambda,
-- `Debug.log`, number clones, local functions and self recursion. Anything else is reported by name.


import Control.Monad (foldM, forM, when)
import Control.Monad.State.Strict (State, execState, gets, modify')
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Char (ord)
import qualified Data.Graph as Graph
import qualified Data.Index as Index
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import qualified Data.Set as Set

import qualified AST.Derive as Derive
import qualified AST.Canonical as Can
import qualified AST.Constraints as Constraints
import qualified AST.Prim.Module as Module
import qualified String
import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeName as T
import qualified AST.WellKnown as WK
import qualified Elm.Float as EF
import qualified Elm.String as ES
import Ficcus.Mono.Class
import Ficcus.Mono.Ir
import Ficcus.Mono.Kernel
import Ficcus.Mono.Effects (Manager(..), effectClassOf, leafKernelId, managerKernelId, mapKernelKind, noStepper, portKernelId)
import qualified Ficcus.Mono.Sized as Sized
import Ficcus.Mono.Overlay (overlayId, overlayModuleName, randomOverlayPrefix, vectorMarker, vectorModuleId, vectorTypeName)
import Ficcus.Mono.Marks (Marks)
import qualified Ficcus.Mono.Marks as Marks
import qualified Ficcus.Mono.Members as Members
import qualified Ficcus.Mono.ContainerMembers as ContainerMembers
import Ficcus.Mono.Modules
import qualified Reporting.Annotation as A
import Type.Dump (Ctx(..), bindDefs, calleeId, canonVars, defIdOf, defKeyOf, kindList, moduleChars, regionText, schemeOf)
import Type.Readout
import qualified Type.Recorder as Recorder



-- THE LIMIT (STAGE3-DESIGN (f)); the message is written here only

keyLimit :: Int
keyLimit = 64


limitMessage :: String -> Key -> String
limitMessage did key =
  "cannot specialize `" ++ did ++ "`: more than " ++ show keyLimit ++ " instances are needed (the last key: "
  ++ shorten (keyText key) ++ "). It is called at types that keep growing: a polymorphic recursion through a `comparable` or `==` variable "
  ++ "(give the function a fixed type or hide the growth in a custom type)."
  where shorten t = if length t > 160 then take 160 t ++ " ..." else t


-- the number of nodes of a type, counted up to a cap (a type that doubles at each step is a shared tree: counting it all would never end)
typeSizeUpTo :: Int -> MType -> Int
typeSizeUpTo cap t = max 0 (cap - go cap t)
  where
    -- the budget left after visiting t
    go budget x
      | budget <= 0 = 0
      | otherwise =
          let b = budget - 1
              kids = case x of
                TyCon _ as -> as
                TyFun a r -> [a, r]
                TyRecord fs -> map snd fs
                TyTuple xs -> xs
                TyUnit -> []
          in foldl go b kids


-- the size of an exact type that stops a specialization: the growth through `(x, x)` doubles the size at each instance
typeSizeLimit :: Int
typeSizeLimit = 4000


growthMessage :: String -> String
growthMessage did =
  "cannot specialize `" ++ did ++ "`: the exact type of its `comparable` or `==` argument grows without end (a type of more than "
  ++ show typeSizeLimit ++ " parts was needed). It is called at types that keep growing: a polymorphic recursion through a `comparable` or "
  ++ "`==` variable (give the function a fixed type or hide the growth in a custom type)."



-- STATE


type Env = Map.Map String KeyPart


data CKey = CKey String (Maybe CloneId) Key
  deriving (Eq, Ord)


data Src =
  Src
    { srcCtx :: Ctx
    , srcDef :: Can.Def
    , srcOuter :: Env
    , srcLocals :: Map.Map String Src
    , srcOwner :: Maybe CloneId
    , srcMembers :: Map.Map String Ref     -- (ATTACH A2) the members that the names of the constraints stand for, inherited by local definitions
    }


data S =
  S
    { sNext :: Int
    , sClones :: Map.Map CKey CloneId
    , sCount :: Map.Map String Int
    , sQueue :: Seq.Seq (CloneId, CKey, Src)
    , sDone :: Map.Map CloneId MDef
    , sErrors :: [String]
    , sMarks :: Marks
    , sTops :: Map.Map String Src
    , sEnums :: Map.Map String Bool
    , sHoist :: Set.Set (String, Int)                   -- local polymorphic values whose let body is being specialized
    , sHoisted :: Map.Map (String, Int) (Set.Set Int)    -- their clones that the body uses (evaluated once at the binding)
    , sPvClass :: Map.Map String Class            -- the class of the variable that holds such a clone's value
    , sVector :: Bool                             -- the program has the overlay's built-in `Vector` (V1): its functions are intrinsics
    , sUnions :: Map.Map String UnionShape        -- (ATTACH A3) every custom type, for `holdsMember`
    , sManagers :: Map.Map String Manager         -- (E1 step 2) the effect modules of the program, by home
    , sLeafHomes :: Set.Set String                -- the managers whose `command` or `subscription` the program uses
    , sMapPairs :: Set.Set (Bool, Class, Class)   -- the (Cmd?, a, b) class pairs of the program's `Cmd.map`/`Sub.map`
    , sAppMsg :: Maybe Class                      -- the class of the program's `msg` (set by `specWorker`)
    , sWorkerFields :: Maybe (SEnv, Can.Expr, Can.Expr)   -- (E1 step 3) `update` and `subscriptions` of the worker, cloned by `workerPhase`
    , sPorts :: Map.Map String Bool               -- (E2 step 7) the ports of the program (`Module.name`, outgoing?)
    , sMemberTable :: Map.Map (String, MType) CloneId   -- (A3b) the member clones the structural ==/compare helpers call
    }


type SM a = State S a


data SEnv =
  SEnv
    { seCtx :: Ctx
    , seEnv :: Env
    , seLocals :: Map.Map String Src
    , seClone :: CloneId
    , seDid :: String        -- the id of the definition being specialized
    , seMembers :: Map.Map String Ref     -- (ATTACH A2) see srcMembers
    }


report :: String -> SM ()
report msg =
  modify' (\s -> if msg `elem` sErrors s then s else s { sErrors = msg : sErrors s })


freshId :: SM CloneId
freshId =
  do  n <- gets sNext
      modify' (\s -> s { sNext = n + 1 })
      return (CloneId n)



-- ENTRY


-- | the program reachable from the `main` of the project, or the messages
specialize :: [ModuleData] -> Marks -> Maybe (Either [String] MProgram)
specialize modules marks =
  case [ (m, d) | m <- modules, mmProject m, d <- mmDefs m, defNameChars d == "main" ] of
    [] -> Nothing
    (m, d) : _ ->
      Just $
      let
        tops = Map.fromList [ (defIdOf (mmCtx m') (defKeyOf d'), Src (mmCtx m') d' Map.empty Map.empty Nothing Map.empty) | m' <- modules, d' <- mmDefs m' ]
        -- V1: the module `Vector` of the overlay declares the built-in vector as a type with one constructor (`vectorMarker`) that is
        -- never built: a reference class, not an enumeration. A module `Vector` of the project does not have it and is ordinary code
        vecOn = or [ n == vectorTypeName && [ c | (c, _, _) <- usCtors u ] == [vectorMarker] | m' <- modules, (n, u) <- mmUnions m' ]
        builtin = if vecOn then Map.insert vectorTypeName False else id
        unions0 = (if vecOn then Map.adjust (\u -> u { usEnum = False }) vectorTypeName else id) (Map.fromList (concatMap mmUnions modules))
        -- SIZED: the sized integers and Float32 of the overlay are scalars (their union is not an enumeration)
        unions = foldr (Map.adjust (\u -> u { usEnum = False })) unions0 [ Sized.typeId sz | sz <- Sized.allSized, Map.member ("sized:" ++ Sized.typeId sz) (Sized.sizedEnums unions0) ]
        enums = Map.union (Sized.sizedEnums unions0) (builtin (Map.fromList (concatMap mmEnums modules)))
        managers = Map.fromList [ (mgHome mg, mg) | m' <- modules, Just mg <- [mmManager m'] ]
        ports = Map.fromList (concatMap mmPorts modules)
        start = S 0 Map.empty Map.empty Seq.empty Map.empty [] marks tops enums Set.empty Map.empty Map.empty vecOn unions managers Set.empty Set.empty Nothing Nothing ports Map.empty
        mainId = defIdOf (mmCtx m) (defKeyOf d)
        -- E1 step 2: the effect managers the program reaches are cloned after everything else (their clones get the last ids)
        -- E1 step 3: update and subscriptions likewise (workerPhase), before the managers their bodies can reach
        final0 = execState (requestRoot mainId >>= \r0 -> drain >> workerPhase mainId >> managerPhase mainId >> return r0) start
        root = Map.lookup (CKey mainId Nothing (Key [])) (sClones final0)
        -- SIZED: a literal out of range is an error also in a definition that `main` does not reach: when a sized type is in the
        -- program, the other definitions of the project are specialized too (their clones are dropped, only these reports are kept)
        final =
          if Map.null (Sized.sizedEnums unions0) then final0
          else
            let ids = [ i | m' <- modules, mmProject m', d' <- mmDefs m', let i = defIdOf (mmCtx m') (defKeyOf d')
                          , not (Map.member (CKey i Nothing (Key [])) (sClones final0)) ]
                extra = execState (mapM_ (\i -> requestRoot i >> drain) ids) final0
                rangeErrs = [ e | e <- reverse (sErrors extra), "@@ INTEGER OUT OF RANGE" `List.isPrefixOf` e, e `notElem` sErrors final0 ]
            in final0 { sErrors = reverse rangeErrs ++ sErrors final0 }
      in
      case (reverse (sErrors final), root) of
        ([], Just r) -> Right (MProgram (ordered (sDone final) (Map.elems (sMemberTable final)) r) (Just r) unions (sMemberTable final))
        ([], Nothing) -> Left [ "internal: main was not requested" ]
        (errs, _) -> Left errs


defNameChars :: Can.Def -> String
defNameChars d =
  case d of
    Can.Def (A.At _ n) _ _ -> N.toChars n
    Can.TypedDef (A.At _ n) _ _ _ _ -> N.toChars n


requestRoot :: String -> SM CloneId
requestRoot mainId =
  do  tops <- gets sTops
      case Map.lookup mainId tops of
        Nothing -> freshId
        Just src -> requestClone (CKey mainId Nothing (Key [])) src


-- | dependencies first: the clones in the order a depth first walk from the root finishes them. A cycle of clones (top level values
-- through a lambda: the `lazy` of parser combinators; only a cycle of two or more values matters) is the exception (FIX2): its members come out together, after everything the
-- cycle depends on, and inside the cycle in the order of the references that run when a value is initialised. A reference to a
-- lifted function (a lambda or local function) that is not called at that place, only made into a closure, runs later, as in Elm's
-- JS output (`cyclic$x()`), so it is not a dependency; a reference from the body of the lifted function is one when it is called.
ordered :: Map.Map CloneId MDef -> [CloneId] -> CloneId -> [MDef]
ordered done extra root =
  -- (A3b) the member clones of the structural helpers (`extra`) are roots too, visited before main (main stays last)
  reverse (snd (foldl visit (Set.empty, []) (extra ++ [root])))
  where
    refsOf c = maybe [] (maybe [] exprRefs . mdBody) (Map.lookup c done)
    strongOf c = maybe [] (maybe [] (eagerRefs done) . mdBody) (Map.lookup c done)
    reachable = Set.toList (go Set.empty (extra ++ [root]))
      where go seen [] = seen
            go seen (c : cs) | Set.member c seen = go seen cs
                             | otherwise = go (Set.insert c seen) (refsOf c ++ cs)
    cycles = Map.fromList [ (c, ms) | Graph.CyclicSCC ms <- Graph.stronglyConnComp [ (c, c, refsOf c) | c <- reachable ]
                                    , length [ () | m <- ms, Just d <- [Map.lookup m done], mdKind d == Value ] > 1, c <- ms ]
    visit (seen, acc) c
      | Set.member c seen = (seen, acc)
      | otherwise =
          case (Map.lookup c cycles, Map.lookup c done) of
            (Just ms, _) ->
              let seen0 = foldr Set.insert seen ms
                  members = c : filter (/= c) ms
                  (seen', acc') = foldl visit (seen0, acc) (concatMap refsOf members)
                  inits = initOrder (Set.fromList ms) members
              in (seen', reverse [ d | m <- inits, Just d <- [Map.lookup m done] ] ++ acc')
            (Nothing, Nothing) -> (Set.insert c seen, acc)
            (Nothing, Just d) ->
              let (seen', acc') = foldl visit (Set.insert c seen, acc) (maybe [] exprRefs (mdBody d))
              in (seen', d : acc')
    -- the members of a cycle, each after the members it needs when it is initialised (depth first over the eager references;
    -- a cycle of those is a bug that Elm's compiler reports earlier: the order is then as the walk finds it)
    initOrder inside members = reverse (snd (foldl step (Set.empty, []) members))
      where
        step (seen, acc) m
          | Set.member m seen = (seen, acc)
          | otherwise = let (seen', acc') = foldl step (Set.insert m seen, acc) [ r | r <- strongOf m, Set.member r inside ] in (seen', m : acc')


-- | the references that are evaluated or called where they stand: not a lifted clone that is only made into a closure
-- (a bare `MGlobal` of a lifted clone, not the function of a call)
eagerRefs :: Map.Map CloneId MDef -> MExpr -> [CloneId]
eagerRefs done e =
  case mNode e of
    MGlobal c -> [ c | not (lifted c) ]
    MCall f args -> (case mNode f of { MGlobal c -> [c]; _ -> eagerRefs done f }) ++ concatMap (eagerRefs done) args
    _ -> concatMap (eagerRefs done) (children e)
  where lifted c = maybe False (\d -> mdLifted d /= Nothing) (Map.lookup c done)


drain :: SM ()
drain =
  do  q <- gets sQueue
      case Seq.viewl q of
        Seq.EmptyL -> return ()
        (cid, ck, src) Seq.:< rest ->
          do  modify' (\s -> s { sQueue = rest })
              def <- genClone cid ck src
              modify' (\s -> s { sDone = Map.insert cid def (sDone s) })
              drain


requestClone :: CKey -> Src -> SM CloneId
requestClone ck@(CKey did _ key) src =
  do  known <- gets (Map.lookup ck . sClones)
      case known of
        Just c -> return c
        Nothing ->
          do  count <- gets (Map.findWithDefault 0 did . sCount)
              cid <- freshId
              modify' (\s -> s { sClones = Map.insert ck cid (sClones s) })
              if count >= keyLimit
                then report (limitMessage did key)
                else modify' (\s -> s { sCount = Map.insert did (count + 1) (sCount s)
                                      , sQueue = sQueue s Seq.|> (cid, ck, src) })
              return cid



-- ONE CLONE


genClone :: CloneId -> CKey -> Src -> SM MDef
genClone cid (CKey did _ key@(Key parts)) src =
  do  let ctx = srcCtx src
      let def = srcDef src
      let (args, body) =
            case def of
              Can.Def _ ps b -> (ps, b)
              Can.TypedDef _ _ tps b _ -> (map fst tps, b)
      scheme <-
        case Map.lookup (defKeyOf def) (_defs (_typed ctx)) of
          Just sch -> return sch
          Nothing -> report ("no scheme recorded for " ++ did) >> return TUnit
      let ownIx = [ (n, i) | (n, i) <- canonVars scheme, not (Map.member n (srcOuter src)) ]
      let own = map fst ownIx
      when (length own /= length parts) $
        report ("internal: " ++ did ++ " has " ++ show (length own) ++ " own variables, the key has " ++ show (length parts))
      let env = Map.union (Map.fromList (zip own parts)) (srcOuter src)
      -- (ATTACH A2) the hidden parameters of a constrained definition are not parameters of the clone: each is the
      -- member function of the exact type of its variable (docs/attach/A2-DESIGN.md section 4)
      let hidden = Constraints.hiddenOfDef def
      members <-
        if null hidden
          then return (srcMembers src)
          else Map.union <$> hiddenMembers did def scheme env hidden <*> pure (srcMembers src)
      let args' = drop (length hidden) args
      let se = SEnv ctx env (srcLocals src) cid did members
      params <- forM (zip [0 :: Int ..] args') (param se)
      body0 <- specExpr se body
      body' <- wrapParams se (zip args' params) body0
      return MDef
        { mdClone = cid, mdName = did, mdKey = key
        , mdKind = if null args && srcOwner src == Nothing then Value else Function     -- (a constrained value is a function without parameters)
        , mdParams = params, mdResult = mRep body', mdBody = Just body'
        , mdInit = Nothing, mdNeeds = [], mdLifted = srcOwner src, mdVars = map snd ownIx, mdOwn = [], mdTwin = Nothing, mdCapsOwned = False }


-- (ATTACH A2) the clone of the member function for each hidden parameter, under the name the body uses
hiddenMembers :: String -> Can.Def -> TType -> Env -> [Constraints.Hidden] -> SM (Map.Map String Ref)
hiddenMembers did def scheme env hidden =
  do  let (types, _) = Members.peel (length hidden) scheme
      refs <- forM (zip3 hidden (Members.subjectNames def scheme) types) $ \(Constraints.Hidden var member local, subject, tipe) ->
        do  let what = "the constraint `" ++ var ++ " has " ++ N.toChars member ++ "` of " ++ did
            case (subject >>= \n -> Map.lookup n env, mtypeOf env tipe) of
              (Just (ByType st), Right mtype) ->
                do  r <- memberRef st (N.toChars member) mtype
                    case r of
                      Left why -> report ("cannot specialize " ++ what ++ ": " ++ why) >> return (N.toChars local, RNone)
                      Right ref -> return (N.toChars local, ref)
              (_, Left why) -> report ("cannot specialize " ++ what ++ ": " ++ why) >> return (N.toChars local, RNone)
              _ -> report ("cannot specialize " ++ what ++ ": the type of `" ++ var ++ "` is not known here") >> return (N.toChars local, RNone)
      return (Map.fromList refs)


-- (ATTACH A3) the function that stands for the member `member` of the exact type `st`, called at the exact member type
-- `mtype`: the clone of the member of a custom type, or for a built-in type (and for `eq` of a custom type that has no such
-- member) the kernel function or definition of elm/core that the member is (AST.WellKnown, the table of the built-in types)
memberRef :: MType -> String -> MType -> SM (Either String Ref)
memberRef st member mtype =
  do  tops <- gets sTops
      unions <- gets sUnions
      case st of
        -- SIZED: the members of a sized type are kernels (the overlay's bodies only give the types)
        TyCon tid _ | Just s <- Sized.sizedEnabled unions tid ->
          return (case Sized.memberOp member of
                    Just op -> sizedKernelRef s op
                    Nothing -> Left ("the type " ++ Sized.typeName s ++ " has no member `" ++ member ++ "`"))
        TyCon tid _ | Map.member (tid ++ "$$" ++ member) tops -> memberClone tid member mtype
        _ -> builtinMember st member


-- the clone of the member `member` of the custom type `tid`
memberClone :: String -> String -> MType -> SM (Either String Ref)
memberClone tid member mtype =
  do  let mid = tid ++ "$$" ++ member
      tops <- gets sTops
      case Map.lookup mid tops of
        Nothing -> return (Left ("the type " ++ tid ++ " has no such member"))
        Just msrc ->
          do  let mdef = srcDef msrc
              let mhidden = Constraints.hiddenCount mdef
              case Map.lookup (defKeyOf mdef) (_defs (_typed (srcCtx msrc))) of
                Nothing -> return (Left ("no scheme recorded for " ++ mid))
                Just mscheme ->
                  case Members.matchM (snd (Members.peel mhidden mscheme)) mtype of
                    Left why -> return (Left why)
                    Right subst ->
                      do  key <- keyForM mid mscheme subst
                          c <- requestClone (CKey mid Nothing key) msrc
                          let arity = length (defArgs mdef) - mhidden
                          return (Right (RClone c arity (arity == 0 && mhidden == 0)))


-- the members of the built-in types are the primitives of elm/core at the exact type: no call, and the generated C is the
-- one of the operator (`add` of Int is the kernel `Basics.add` at the key [Int])
builtinMember :: MType -> String -> SM (Either String Ref)
builtinMember st member =
  do  enums <- gets sEnums
      tops <- gets sTops
      let numKey = Key [ByType st]
      let kernel cid key =
            case kernelArity cid of
              Just arity -> return (Right (RKernel cid key arity))
              Nothing -> return (Left ("`" ++ cid ++ "` is not in the kernel table"))
      let basics n = "elm/core:Basics." ++ n
      case member of
        "add" -> kernel (basics "add") numKey
        "sub" -> kernel (basics "sub") numKey
        "mul" -> kernel (basics "mul") numKey
        "pow" -> kernel (basics "pow") numKey
        "neg" -> kernel (basics "negate") numKey
        "abs" ->
          case Map.lookup (basics "abs") tops of
            Just src -> (\c -> Right (RClone c 1 False)) <$> requestClone (CKey (basics "abs") Nothing numKey) src
            Nothing -> return (Left "`Basics.abs` has no definition")
        "compare" -> kernel (basics "compare") numKey
        "eq" -> kernel (basics "eq") numKey
        "div" -> kernel (basics "fdiv") (Key [])
        "idiv" -> kernel (basics "idiv") (Key [])
        "mod" -> kernel (basics "modBy") (Key [])
        "rem" -> kernel (basics "remainderBy") (Key [])
        "fromFloat" | st == TyCon "elm/core:Basics.Float" [] ->
          case Map.lookup (basics "identity") tops of
            Just src -> (\c -> Right (RClone c 1 False)) <$> requestClone (CKey (basics "identity") Nothing (Key [ByClass CF64])) src
            Nothing -> return (Left "`Basics.identity` has no definition")
        "fromInt"
          | st == TyCon "elm/core:Basics.Float" [] -> kernel (basics "toFloat") (Key [])
          | otherwise ->
              case Map.lookup (basics "identity") tops of
                Just src -> (\c -> Right (RClone c 1 False)) <$> requestClone (CKey (basics "identity") Nothing (Key [ByClass CI64])) src
                Nothing -> return (Left "`Basics.identity` has no definition")
        "append" ->
          case st of
            TyCon "elm/core:List.List" [e] -> kernel (basics "append") (Key [ByApp (AList (boxed (classOfM enums e)))])
            _ -> kernel (basics "append") (Key [ByApp AStr])
        _ -> return (Left ("the type " ++ mtypeText st ++ " has no member `" ++ member ++ "`"))


-- (ATTACH A3) an operator or a function of Basics at a custom type that has the member behind it: the clone of the member
-- (`a + b` at `Money` is `Money.add a b`, a direct call; `compare`, `==`, `negate`, `abs`, `++`, `/`, `//`, `modBy`, `remainderBy` the same).
-- The first parameter of the instance of the callee is the type.  `Nothing`: not such a use.
wellKnownRef :: SEnv -> String -> Maybe TType -> SM (Maybe Ref)
wellKnownRef se cid inst =
  case (WK.operatorMember cid, inst >>= peelFun 1) of
    (Just member, Just ([first], _)) | Right t <- mtypeOf (seEnv se) first ->
      do  tops <- gets sTops
          unions <- gets sUnions
          case t of
            -- SIZED: an operator at a sized type is its kernel
            TyCon tid _ | Just s <- Sized.sizedEnabled unions tid, Just op <- Sized.operatorOp cid ->
              case sizedKernelRef s op of
                Right ref -> return (Just ref)
                Left why -> report ("cannot specialize `" ++ cid ++ "` at " ++ mtypeText t ++ ": " ++ why) >> return (Just RNone)
            TyCon tid _ | Map.member (tid ++ "$$" ++ member) tops ->
              if cid `elem` derived
                then return Nothing
                else
                  do  let shape = maybe WK.Binary id (WK.shapeOf member)
                      r <- memberClone tid member (shapeType shape t)
                      case r of
                        Left why -> report ("cannot specialize `" ++ cid ++ "` at " ++ mtypeText t ++ ": " ++ why) >> return (Just RNone)
                        Right ref -> return (Just ref)
            -- a relaxed `/ // modBy remainderBy` inside a generic function (`a has div`) at Float or Int: its instance type is the
            -- variable, which does not match the scheme of the kernel function (Float -> Float -> Float), so say which member it is
            _ | isVar first, member `elem` ["div", "idiv", "mod", "rem"], t `elem` [TyCon "elm/core:Basics.Float" [], TyCon "elm/core:Basics.Int" []] ->
              do  r <- builtinMember t member
                  case r of
                    Left why -> report ("cannot specialize `" ++ cid ++ "` at " ++ mtypeText t ++ ": " ++ why) >> return (Just RNone)
                    Right ref -> return (Just ref)
            _ ->
              do  containerMembers cid member t
                  return Nothing
    _ -> return Nothing
  where
    isVar ty = case ty of { TVar {} -> True; TAlias _ _ _ real -> isVar real; _ -> False }


-- | (A3b) `==` and the comparisons at a type that holds custom types with the member (a list, tuple, record, `Maybe`, `Dict`, a
-- custom type with one in a field): the structural helpers of the C generator call the member of each such type, so its clone
-- is requested here and recorded in `sMemberTable` (docs/A3B-PLAN.md section 2).  A sized type inside is a scalar of the
-- structural code (Word64 is compared unsigned there).
containerMembers :: String -> String -> MType -> SM ()
containerMembers cid member t =
  when (member `elem` ["eq", "compare"]) $
    do  tops <- gets sTops
        unions <- gets sUnions
        let has tid = Map.member (tid ++ "$$" ++ member) tops
            skip tid = Sized.sizedEnabled unions tid /= Nothing
        case ContainerMembers.membersInside has skip unions t of
          Left why -> report ("`" ++ cid ++ "` at " ++ mtypeText t ++ ": " ++ why)
          Right ts -> mapM_ (containerMember member) ts


containerMember :: String -> MType -> SM ()
containerMember member st =
  case st of
    TyCon tid _ ->
      do  known <- gets (Map.member (member, st) . sMemberTable)
          when (not known) $
            do  let shape = maybe WK.Binary id (WK.shapeOf member)
                r <- memberClone tid member (shapeType shape st)
                case r of
                  Right (RClone c 2 _) -> record c
                  Right (RClone c arity isVal) -> etaMember tid member st c arity isVal >>= record
                  Right _ -> report ("internal: the `" ++ member ++ "` member of " ++ mtypeText st ++ " is not a clone")
                  Left why -> report ("cannot specialize the `" ++ member ++ "` member of " ++ mtypeText st ++ ", which `==` or `compare` of a type that holds it calls: " ++ why)
    _ -> return ()
  where
    record :: CloneId -> SM ()
    record c = modify' (\s -> s { sMemberTable = Map.insert (member, st) c (sMemberTable s) })


-- | (A3b) a member not written with two parameters (`compare = byKey`, `compare (V a) = \(V b) -> ...`): a clone of two
-- parameters that applies it, so that the C helpers always make a direct call of two arguments
etaMember :: String -> String -> MType -> CloneId -> Int -> Bool -> SM CloneId
etaMember tid member st c arity isVal =
  do  enums <- gets sEnums
      w <- freshId
      let cls = classOfM enums st
          res = classOfM enums (TyCon (if member == "eq" then "elm/core:Basics.Bool" else "elm/core:Basics.Order") [])
          params = [ ("_ma", cls), ("_mb", cls) ]
          locals = [ MExpr k (MLocal n) | (n, k) <- params ]
          (first, rest) = splitAt arity locals
          inner
            | null first = if isVal then MGlobal c else MCall (MExpr CRef (MGlobal c)) []
            | otherwise = MCall (MExpr CRef (MGlobal c)) first
          body = if null rest then MExpr res inner else MExpr res (MCall (MExpr CRef inner) rest)
      modify' (\s -> s { sDone = Map.insert w
                         (MDef { mdClone = w, mdName = tid ++ "$$" ++ member ++ "$eta", mdKey = Key [], mdKind = Function
                               , mdParams = params, mdResult = res, mdBody = Just body, mdInit = Nothing, mdNeeds = []
                               , mdLifted = Nothing, mdVars = [], mdOwn = [], mdTwin = Nothing, mdCapsOwned = False })
                         (sDone s) })
      return w


-- (SIZED) `author/project:Int8.toInt`: the name and the type, when the module is the overlay's
sizedModuleFunction :: Map.Map String UnionShape -> String -> Maybe (String, Sized.Sized)
sizedModuleFunction unions cid =
  case [ (n, sz) | sz <- Sized.allSized, Just n <- [List.stripPrefix ("author/project:" ++ Sized.typeName sz ++ ".") cid], Just _ <- [Sized.sizedEnabled unions (Sized.typeId sz)] ] of
    r : _ -> Just r
    [] -> Nothing


-- (SIZED) the kernel of an operation of a sized type
sizedKernelRef :: Sized.Sized -> String -> Either String Ref
sizedKernelRef s op =
  let cid = Sized.kernelId s op
  in case kernelArity cid of
       Just arity -> Right (RKernel cid (Key []) arity)
       Nothing -> Left ("`" ++ cid ++ "` is not in the kernel table")


-- (SIZED) the sized type of a node, when it is one of the overlay's
sizedOfNode :: SEnv -> Recorder.Key -> SM (Maybe Sized.Sized)
sizedOfNode se key =
  case nodeType se key of
    Just t | Right (TyCon tid _) <- mtypeOf (seEnv se) t ->
      do  unions <- gets sUnions
          return (Sized.sizedEnabled unions tid)
    _ -> return Nothing


-- (SIZED) an integer literal at a sized type: checked against the range at compile time, held as the constant (a Float32 beyond
-- 2^24 is converted at run time so that it is rounded as C rounds)
sizedLiteral :: SEnv -> Sized.Sized -> Bool -> Integer -> A.Region -> Class -> SM MExpr
sizedLiteral se s negated n region cls =
  case Sized.literalValue s negated n of
    Left why ->
      do  report ("@@ INTEGER OUT OF RANGE\n" ++ regionText region ++ " in " ++ seDid se ++ "\n\n" ++ why)
          return (MExpr cls (MLit (LInt 0)))
    Right v
      | Sized.isFloat s ->
          if Sized.literalNeedsCall s v
            then return (MExpr cls (MCall (MExpr CRef (MKernel (Sized.kernelId s "fromInt") (Key []))) [MExpr CI64 (MLit (LInt v))]))
            else return (MExpr cls (MLit (LFloat (fromIntegral v))))
      | otherwise -> return (MExpr cls (MLit (LInt v)))


-- the functions that are not the member itself but are made from it (the overlay: FicOverlay.ficLt ...)
derived :: [String]
derived =
  [ "elm/core:Basics.lt", "elm/core:Basics.gt", "elm/core:Basics.le", "elm/core:Basics.ge", "elm/core:Basics.neq" ]


-- | `<`, `>`, `<=`, `>=` at a type with `compare`, `/=` at a type with `eq`: the definition in the overlay
wellKnownDerived :: SEnv -> String -> Maybe TType -> SM (Maybe String)
wellKnownDerived se cid inst =
  case (lookup cid table, inst >>= peelFun 1) of
    (Just (member, name), Just ([first], _)) | Right (TyCon tid _) <- mtypeOf (seEnv se) first ->
      do  tops <- gets sTops
          return (if Map.member (tid ++ "$$" ++ member) tops then Just ("author/project:" ++ overlayModuleName ++ "." ++ name) else Nothing)
    _ -> return Nothing
  where
    table =
      [ ("elm/core:Basics.lt", ("compare", "ficLt")), ("elm/core:Basics.gt", ("compare", "ficGt"))
      , ("elm/core:Basics.le", ("compare", "ficLe")), ("elm/core:Basics.ge", ("compare", "ficGe"))
      , ("elm/core:Basics.neq", ("eq", "ficNeq")) ]


-- | (H21 and ATTACH A3) `Vector.sort` and `Vector.sortPerm` (the kernels compare structurally) at an element type that has a `compare`
-- member inside (a custom type with its own `compare`, a tuple, record or list holding one, or Word64, whose order is not the signed one):
-- the definitions `sortMember`/`sortPermMember` of the Vector overlay, which sort with `compare`, so that the member is called (or the
-- error of `wellKnownRef` is given for a type that holds one inside). `List.sort` and `List.sortBy` go through these two.
vectorSortMember :: SEnv -> String -> Maybe TType -> SM (Maybe String)
vectorSortMember se cid inst =
  case (List.stripPrefix vectorModuleId cid, inst >>= peelFun 1) of
    (Just n, Just ([first], _))
      | n `elem` ["sort", "sortPerm"], Right (TyCon vt [e]) <- mtypeOf (seEnv se) first, vt == vectorTypeName ->
          do  on <- gets sVector
              tops <- gets sTops
              unions <- gets sUnions
              return (if on && holdsMember tops unions "compare" e /= Nothing then Just (vectorModuleId ++ n ++ "Member") else Nothing)
    _ -> return Nothing


-- the member of the exact type `t` that the language needs, as a type
shapeType :: WK.Shape -> MType -> MType
shapeType shape t =
  case shape of
    WK.Binary -> TyFun t (TyFun t t)
    WK.Compare -> TyFun t (TyFun t (TyCon "elm/core:Basics.Order" []))
    WK.Equal -> TyFun t (TyFun t (TyCon "elm/core:Basics.Bool" []))
    WK.Unary -> TyFun t t
    WK.FromInt -> TyFun (TyCon "elm/core:Basics.Int" []) t
    WK.FromFloat -> TyFun (TyCon "elm/core:Basics.Float" []) t


-- a custom type with the member inside an exact type (its type arguments, tuple and record parts, and the constructor fields of
-- custom types, followed through aliases (already expanded in the unions) and across modules): the path of type names from the
-- type to the one with the member.  A type is entered once (`seen`), so recursive and mutually recursive types end.
holdsMember :: Map.Map String a -> Map.Map String UnionShape -> String -> MType -> Maybe [String]
holdsMember tops unions member t0 = fst (go Set.empty [] t0)
  where
    go seen path t =
      case t of
        -- SIZED: a sized type is held as a scalar, which the structural code treats right (but Word64, held as signed bits, in an order)
        TyCon tid _
          | Just sz <- Sized.sizedEnabled unions tid -> (if member == "compare" && Sized.wordWithoutStructuralOrder sz then Just (reverse (tid : path)) else Nothing, seen)
        TyCon tid args
          | Map.member (tid ++ "$$" ++ member) tops -> (Just (reverse (tid : path)), seen)
          | otherwise ->
              case goAll seen path args of
                (Just r, seen') -> (Just r, seen')
                (Nothing, seen')
                  | Set.member tid seen' -> (Nothing, seen')
                  | otherwise ->
                      case Map.lookup tid unions of
                        Just u -> goAll (Set.insert tid seen') (tid : path) [ f | (_, _, fs) <- usCtors u, f <- map (subst args) fs ]
                        Nothing -> (Nothing, seen')
        TyTuple xs -> goAll seen path xs
        TyRecord fs -> goAll seen path (map snd fs)
        _ -> (Nothing, seen)
    goAll seen _ [] = (Nothing, seen)
    goAll seen path (x : xs) =
      case go seen path x of
        (Just r, seen') -> (Just r, seen')
        (Nothing, seen') -> goAll seen' path xs
    -- the parameters of a union are `TyCon "#i" []`
    subst args ty =
      case ty of
        TyCon ('#' : ds) [] | [(i, "")] <- reads ds, i < length args -> args !! i
        TyCon c xs -> TyCon c (map (subst args) xs)
        TyFun a b -> TyFun (subst args a) (subst args b)
        TyRecord fs -> TyRecord [ (f, subst args x) | (f, x) <- fs ]
        TyTuple xs -> TyTuple (map (subst args) xs)
        TyUnit -> TyUnit


-- the key of a definition for the exact types of its variables (`keyFor` for types without variables)
keyForM :: String -> TType -> Map.Map String MType -> SM Key
keyForM cid scheme subst =
  do  marks <- gets sMarks
      enums <- gets sEnums
      let kinds = kindList scheme
      parts <- forM (canonVars scheme) $ \(n, i) ->
        do  let kind = if i < length kinds then kinds !! i else "any"
            let marked = not (Set.null (Marks.marksOf marks cid i)) || forcedExact cid i
            let exact = kind `elem` ["number", "comparable", "compappend"] || marked
            case Map.lookup n subst of
              Nothing
                | exact -> return (ByType (TyCon "ref" []))
                | kind == "appendable" -> return (ByApp AStr)
                | otherwise -> return (ByClass CRef)
              Just m
                | kind == "row" -> report ("cannot key the row variable v" ++ show i ++ " of the member " ++ cid) >> return (ByLayout [])
                | exact -> return (ByType m)
                | kind == "appendable" ->
                    do  tops <- gets sTops
                        return $ case m of
                          TyCon tid _ | Map.member (tid ++ "$$append") tops -> ByType m
                          TyCon "elm/core:List.List" [e] -> ByApp (AList (boxed (classOfM enums e)))
                          _ -> ByApp AStr
                | otherwise -> return (ByClass (boxed (classOfM enums m)))
      return (Key parts)


param :: SEnv -> (Int, Can.Pattern) -> SM (String, Class)
param se (i, pat@(A.At region p)) =
  do  cls <- patClass se pat
      case p of
        Can.PVar n -> return (N.toChars n, cls)
        Can.PAnything -> return ("_a" ++ show i, cls)
        _ -> return ("_p" ++ show i, cls)          -- a pattern: matched in the body (wrapParams)
  where _ = region


-- the patterns of the parameters of a definition become cases on the parameter, outermost first
wrapParams :: SEnv -> [(Can.Pattern, (String, Class))] -> MExpr -> SM MExpr
wrapParams se ps body0 =
  foldM wrap body0 (reverse ps)
  where
    wrap acc (pat@(A.At _ p), (n, cls)) =
      case p of
        Can.PVar _ -> return acc
        Can.PAnything -> return acc
        _ ->
          do  pat' <- specPat se pat
              return (MExpr (mRep acc) (MCase (MExpr cls (MLocal n)) [(pat', acc)]))


patClass :: SEnv -> Can.Pattern -> SM Class
patClass se (A.At region p) =
  case nodeType se (Recorder.patKey region p) of
    Nothing -> report "internal: no type for a pattern" >> return CRef
    Just t -> classOfTy se t



-- TYPES AND CLASSES


-- the type of a node with its dead variables defaulted
nodeType :: SEnv -> Recorder.Key -> Maybe TType
nodeType se key =
  fmap (applyDefault (\n -> not (Map.member n (seEnv se)))) (Map.lookup key (_nodes (_typed (seCtx se))))


classOfTy :: SEnv -> TType -> SM Class
classOfTy se t =
  do  enums <- gets sEnums
      case unresolvedNumber (seEnv se) t of
        Just n -> report ("internal: the `number` variable " ++ n ++ " of a node in " ++ seDid se ++ " is not resolved (not defaulted to Int)")
        Nothing -> return ()
      return (classOfT enums (seEnv se) t)


-- (A3c) a `number` variable that is neither a variable of the clone (in the environment) nor defaulted (`applyDefault` makes a
-- dead one Int): its values could be Int or Float, so no representation can be chosen.  Every node type is defaulted, so this
-- is a path of the specializer that skipped the defaulting (F7 was one); the build stops with an internal error, never a crash
unresolvedNumber :: Env -> TType -> Maybe String
unresolvedNumber env t =
  case t of
    TVar n KNumber _ | not (Map.member n env) -> Just n
    TVar _ _ _ -> Nothing
    TCon _ _ args -> firstJust args
    TFun a b -> firstJust [a, b]
    TPair a b -> firstJust [a, b]
    TTriple a b c -> firstJust [a, b, c]
    TRecord fields _ -> firstJust (Map.elems fields)
    TAlias _ _ _ real -> unresolvedNumber env real
    _ -> Nothing
  where
    firstJust ts = case [ n | Just n <- map (unresolvedNumber env) ts ] of { n : _ -> Just n; [] -> Nothing }


classOfT :: Map.Map String Bool -> Env -> TType -> Class
classOfT enums env t =
  case t of
    TCon h n args ->
      let name = moduleChars h ++ "." ++ N.toChars (T.nameToName n)
      in classOfName enums name (length args)
    TFun _ _ -> CRef
    TUnit -> CUnit
    TPair a b -> CStruct [boxed (go a), boxed (go b)]
    TTriple a b c -> CStruct [boxed (go a), boxed (go b), boxed (go c)]
    TRecord fields Nothing -> CStruct (map (boxed . go) (Map.elems fields))
    TRecord _ (Just _) -> maybe CRef (CStruct . map snd) (rowFieldsT enums env t)
    TVar n _ _ ->
      case Map.lookup n env of
        Just (ByClass c) -> c
        Just (ByType m) -> classOfM enums m
        Just (ByApp _) -> CRef
        Just (ByLayout fs) -> CStruct (map snd fs)
        Nothing -> CRef
    TAlias _ _ _ real -> go real
    TRef _ -> CRef
    TError -> CRef
  where
    go = classOfT enums env


-- all the fields of a record type with their (boxed) classes, in the order of N.Name (shorter names first, then by
-- characters; Elm's Map of fields) that is the order of the struct. An extensible record `{ a | x : Float }` is
-- completed from the layout that its row variable has in the key (ByLayout: the fields the variable stands for)
rowFieldsT :: Map.Map String Bool -> Env -> TType -> Maybe [(String, Class)]
rowFieldsT enums env t =
  case t of
    TRecord fs Nothing -> Just (own fs)
    TRecord fs (Just ext) ->
      case strip ext of
        TVar n _ _ | Just (ByLayout ls) <- Map.lookup n env -> Just (List.sortOn (\(k, _) -> (length k, k)) (own fs ++ ls))
        TRecord fs2 e2 -> rowFieldsT enums env (TRecord (Map.union fs fs2) e2)
        _ -> Nothing
    TVar n _ _ | Just (ByLayout ls) <- Map.lookup n env -> Just ls
    TAlias _ _ _ real -> rowFieldsT enums env real
    _ -> Nothing
  where
    own fs = [ (N.toChars k, boxed (classOfT enums env v)) | (k, v) <- Map.toList fs ]


classOfName :: Map.Map String Bool -> String -> Int -> Class
classOfName enums name _ =
  case name of
    _ | Map.member ("sized:" ++ name) enums, Just s <- Sized.sizedOfTypeId name -> Sized.classOfSized s
    _ | Just c <- effectClassOf name -> c           -- E1: the platform kernel types (Ficcus.Mono.Effects)
    "elm/core:Basics.Int" -> CI64
    "elm/core:Basics.Float" -> CF64
    "elm/core:Char.Char" -> CU32
    "elm/core:Basics.Bool" -> CEnum
    "elm/core:String.String" -> CRef         -- declared as a one constructor type in elm/core, but a built-in
    "elm/core:List.List" -> CRef
    "elm/core:Elm.JsArray.JsArray" -> CRef   -- declared without constructors, a built-in (runtime/fic_jsarray.h)
    "elm/json:Json.Encode.Value" -> CRef      -- declared with one constructor without fields: built-ins (runtime/fic_json.h, fic_bytes.h)
    "elm/json:Json.Decode.Decoder" -> CRef
    "elm/bytes:Bytes.Bytes" -> CRef
    "elm/regex:Regex.Regex" -> CRef            -- declared with one constructor without fields: the compiled program (runtime/fic_regex.h)
    "author/project:FicOverlayRegex.Caps" -> CRef
    _ -> case Map.lookup name enums of { Just True -> CEnum; _ -> CRef }


classOfM :: Map.Map String Bool -> MType -> Class
classOfM enums t =
  case t of
    TyCon n args -> classOfName enums n (length args)
    TyFun _ _ -> CRef
    TyRecord fs -> CStruct [ boxed (classOfM enums x) | (_, x) <- fs ]
    TyTuple xs -> CStruct (map (boxed . classOfM enums) xs)
    TyUnit -> CUnit


-- a struct that reaches an unconstrained variable is boxed (STAGE3-DESIGN section 0); so is a struct that is a
-- field of a struct, a field of a constructor or an element of a list: the layout of a type then does not
-- depend on the key, and the only places that convert are the variable positions (CGen `adapt`)
boxed :: Class -> Class
boxed c =
  case c of
    CStruct _ -> CRef
    _ -> c


mtypeOf :: Env -> TType -> Either String MType
mtypeOf env t =
  case t of
    TCon h n args -> TyCon (moduleChars h ++ "." ++ N.toChars (T.nameToName n)) <$> mapM go args
    TFun a b -> TyFun <$> go a <*> go b
    TUnit -> Right TyUnit
    TPair a b -> (\x y -> TyTuple [x, y]) <$> go a <*> go b
    TTriple a b c -> (\x y z -> TyTuple [x, y, z]) <$> go a <*> go b <*> go c
    TRecord fields Nothing -> TyRecord <$> mapM (\(k, v) -> (,) (N.toChars k) <$> go v) (Map.toList fields)
    TRecord _ (Just _) -> Left "an extensible record in an exact type (row variables: slice 5)"
    TVar n k _ ->
      case Map.lookup n env of
        Just (ByType m) -> Right m
        Just _ -> Left ("the variable " ++ n ++ " is used at an exact type but is keyed by class")
        Nothing | KNumber <- k -> Left ("internal: the `number` variable " ++ n ++ " is not resolved (not defaulted to Int)")
        Nothing -> Right (TyCon "ref" [])
    TAlias _ _ _ real -> go real
    TRef _ -> Right (TyCon "ref" [])
    TError -> Left "type error node"
  where
    go = mtypeOf env


appClassOf :: Map.Map String Bool -> Env -> TType -> AppClass
appClassOf enums env t =
  case t of
    TCon h n [e] | moduleChars h ++ "." ++ N.toChars (T.nameToName n) == "elm/core:List.List" -> AList (boxed (classOfT enums env e))
    TCon _ _ _ -> AStr
    TAlias _ _ _ real -> appClassOf enums env real
    TVar n _ _ ->
      case Map.lookup n env of
        Just (ByApp a) -> a
        Just (ByType (TyCon "elm/core:List.List" [e])) -> AList (boxed (classOfM enums e))
        _ -> AStr
    _ -> AStr



-- KEYS


keyFor :: SEnv -> String -> TType -> Subst -> (String -> Bool) -> SM Key
keyFor se cid scheme subst isOuter =
  do  marks <- gets sMarks
      enums <- gets sEnums
      let kinds = kindList scheme
      let env = seEnv se
      let dead n = not (Map.member n env)
      parts <- forM [ (n, i) | (n, i) <- canonVars scheme, not (isOuter n) ] $ \(n, i) ->
        do  let kind = if i < length kinds then kinds !! i else "any"
            let t = maybe (defaultKind KAny) (applyDefault dead) (Map.lookup n subst)
            let marked = not (Set.null (Marks.marksOf marks cid i)) || forcedExact cid i
            case () of
              _ | kind == "row" ->
                    case rowFieldsT enums env t of
                      Just fl -> return (ByLayout fl)
                      Nothing -> report ("cannot key the row variable v" ++ show i ++ " of " ++ cid) >> return (ByLayout [])
                | kind `elem` ["number", "comparable", "compappend"] || marked ->
                    case mtypeOf env t of
                      Right m | typeSizeUpTo typeSizeLimit m >= typeSizeLimit -> report (growthMessage cid) >> return (ByType (TyCon "ref" []))
                      Right m -> return (ByType m)
                      Left why -> report ("cannot key " ++ cid ++ " v" ++ show i ++ ": " ++ why) >> return (ByClass CRef)
                | kind == "appendable" ->
                    do  tops <- gets sTops
                        -- (ATTACH A3) a custom type with an `append` member is keyed by its exact type
                        case mtypeOf env t of
                          Right m@(TyCon tid _) | Map.member (tid ++ "$$append") tops -> return (ByType m)
                          _ -> return (ByApp (appClassOf enums env t))
                | otherwise -> return (ByClass (boxed (classOfT enums env t)))
      return (Key parts)


-- EXPRESSIONS


unitLit :: MExpr
unitLit = MExpr CUnit (MLit LUnit)


-- (ATTACH A3) the exact type of a node when it is a custom type that has well known members (`Money`), else Nothing
customTypeOf :: SEnv -> Recorder.Key -> SM (Maybe MType)
customTypeOf se key =
  case nodeType se key of
    Just t | Right m@(TyCon tid _) <- mtypeOf (seEnv se) t ->
      do  tops <- gets sTops
          return (if Map.member (tid ++ "$$fromInt") tops || Map.member (tid ++ "$$neg") tops then Just m else Nothing)
    _ -> return Nothing


-- (A3b) the type of a Float literal when it is not Float: Float32 (Left) or a custom type with `fromFloat` (Right)
floatLiteralAt :: SEnv -> Recorder.Key -> SM (Maybe (Either Sized.Sized MType))
floatLiteralAt se key =
  case nodeType se key of
    Just t | Right m@(TyCon tid _) <- mtypeOf (seEnv se) t ->
      do  tops <- gets sTops
          unions <- gets sUnions
          return $ case Sized.sizedEnabled unions tid of
            Just s | Sized.isFloat s -> Just (Left s)
            _ | Map.member (tid ++ "$$fromFloat") tops -> Just (Right m)
            _ -> Nothing
    _ -> return Nothing


-- the class of a node of the Canonical tree, from its recorded type
exprClass :: SEnv -> A.Region -> Can.Expr_ -> SM Class
exprClass se region e =
  case nodeType se (Recorder.exprKey region e) of
    Just t -> classOfTy se t
    Nothing -> report ("internal: no type for " ++ Recorder.exprKind e ++ " at " ++ regionText region) >> return CRef


specExpr :: SEnv -> Can.Expr -> SM MExpr
specExpr se (A.At region e) =
  case e of
    Can.Chr c -> return (MExpr CU32 (MLit (LChar (ord c))))
    Can.Str s -> return (MExpr CRef (MLit (LString (unescape (ES.toChars s)))))
    Can.Int n ->
      do  cls <- exprClass se region e
          sz <- sizedOfNode se (Recorder.exprKey region e)
          custom <- customTypeOf se (Recorder.exprKey region e)
          case custom of
            _ | Just s <- sz -> sizedLiteral se s False (toInteger n) region cls
            -- (ATTACH A3) an integer literal at a custom type is `fromInt` of it
            Just t@(TyCon tid _) ->
              do  r <- memberClone tid "fromInt" (shapeType WK.FromInt t)
                  case r of
                    Right (RClone c _ _) -> return (MExpr cls (MCall (MExpr CRef (MGlobal c)) [MExpr CI64 (MLit (LInt (fromIntegral n)))]))
                    Right _ -> report ("internal: fromInt of " ++ tid ++ " is not a function") >> return (MExpr cls (MLit (LInt 0)))
                    Left why -> report ("cannot specialize the literal " ++ show n ++ " at " ++ tid ++ ": " ++ why ++ " (a literal at a custom type is its `fromInt`)") >> return (MExpr cls (MLit (LInt 0)))
            _ -> return (MExpr cls (MLit (if cls == CF64 then LFloat (fromIntegral n) else LInt (fromIntegral n))))
    Can.Float f ->
      do  let lit = MExpr CF64 (MLit (LFloat (readDouble (BLC.unpack (BB.toLazyByteString (EF.toBuilder f))))))
          at <- floatLiteralAt se (Recorder.exprKey region e)
          case at of
            Nothing -> return lit
            -- (A3b) a Float literal at Float32 is the kernel of Float32.fromFloat (rounded to a float), at a custom type its `fromFloat`
            Just (Left s) ->
              do  cls <- exprClass se region e
                  return (MExpr cls (MCall (MExpr CRef (MKernel (Sized.kernelId s "fromFloat") (Key []))) [lit]))
            Just (Right t@(TyCon tid _)) ->
              do  cls <- exprClass se region e
                  r <- memberClone tid "fromFloat" (shapeType WK.FromFloat t)
                  case r of
                    Right (RClone c 1 _) -> return (MExpr cls (MCall (MExpr CRef (MGlobal c)) [lit]))
                    Right (RClone c 0 isVal) -> return (MExpr cls (MCall (MExpr CRef (if isVal then MGlobal c else MCall (MExpr CRef (MGlobal c)) [])) [lit]))
                    Right _ -> report ("internal: fromFloat of " ++ tid ++ " is not a function of one parameter") >> return lit
                    Left why -> report ("cannot specialize a Float literal at " ++ tid ++ ": " ++ why ++ " (a Float literal at a custom type is its `fromFloat`)") >> return lit
            Just (Right _) -> return lit
    Can.Unit -> return unitLit
    Can.Negate (A.At ir (Can.Int n)) ->
      do  sz <- sizedOfNode se (Recorder.exprKey region e)
          case sz of
            Just s -> exprClass se region e >>= sizedLiteral se s True (toInteger n) region
            Nothing -> specNegate se region e (A.At ir (Can.Int n))
    Can.Negate x -> specNegate se region e x
    Can.Pair a b ->
      do  cls <- exprClass se region e
          a' <- specExpr se a
          b' <- specExpr se b
          return (MExpr cls (MTuple [a', b']))
    Can.Triple a b c ->
      do  cls <- exprClass se region e
          xs <- mapM (specExpr se) [a, b, c]
          return (MExpr cls (MTuple xs))
    Can.Record fields ->
      do  cls <- exprClass se region e
          fs <- forM (Map.toList fields) (\(k, v) -> (,) (N.toChars k) <$> specExpr se v)
          return (MExpr cls (MRecord fs))
    Can.If branches final ->
      do  cls <- exprClass se region e
          bs <- forM branches (\(c, b) -> (,) <$> specExpr se c <*> specExpr se b)
          f <- specExpr se final
          return (MExpr cls (MIf bs f))
    Can.Let def body -> specLet se [def] False body
    Can.LetRec defs body -> specLet se defs True body
    Can.LetDestruct (A.At _ Can.PAnything) x body ->
      do  x' <- specExpr se x
          b' <- specExpr se body
          return (MExpr (mRep b') (MSeq x' b'))
    Can.List xs ->
      do  cls <- exprClass se region e
          xs' <- mapM (specExpr se) xs
          return (MExpr cls (MList xs'))
    -- { r | a = x, b = y }: r is evaluated first, then the new values in the order of Elm's Map of field names (shorter names first, then alphabetical; Elm's
    -- `_Utils_update(r, {a: x, b: y})`); a new record of the same layout takes the other fields from r
    Can.Update _ r@(A.At rregion r') updates ->
      do  cls <- exprClass se region e
          r'' <- specExpr se r
          enums <- gets sEnums
          let fields = case nodeType se (Recorder.valueKey rregion r') of
                Just t -> map fst <$> rowFieldsT enums (seEnv se) t
                Nothing -> Nothing
          case (fields, cls) of
            (Just names, CStruct fcs) | length names == length fcs ->
              do  CloneId k <- freshId
                  let tmp = "_up" ++ show k
                  news <- forM (Map.toList updates) (\(n, Can.FieldUpdate _ v) -> (,) (N.toChars n) <$> specExpr se v)
                  let old' = MExpr (mRep r'') (MLocal tmp)
                  let field (i, (n, c)) = (n, case lookup n news of { Just v -> v; Nothing -> MExpr c (MAccess old' n i) })
                  let rec = MExpr cls (MRecord (map field (zip [0 ..] (zip names fcs))))
                  -- every field replaced: the old record is only evaluated (it may have an effect)
                  return (if length news == length names then MExpr cls (MSeq r'' rec) else MExpr (mRep r'') (MLetVal tmp r'' rec))
            _ -> unsupported "a record update on an extensible record (row polymorphism: slice 5)" region
    Can.Access r@(A.At rregion r') (A.At _ fld) ->
      do  cls <- exprClass se region e
          r'' <- specExpr se r
          enums <- gets sEnums
          let fields = case nodeType se (Recorder.valueKey rregion r') of
                Just t -> map fst <$> rowFieldsT enums (seEnv se) t
                Nothing -> Nothing
          case fields >>= \fs -> lookup (N.toChars fld) (zip fs [0 :: Int ..]) of
            Just i -> return (MExpr cls (MAccess r'' (N.toChars fld) i))
            Nothing -> unsupported "a field access on an extensible record (row polymorphism: slice 5)" region
    Can.Case scrut branches ->
      do  cls <- exprClass se region e
          s' <- specExpr se scrut
          bs <- forM branches (\(Can.CaseBranch p b) -> (,) <$> specPat se p <*> specExpr se b)
          return (MExpr cls (MCase s' bs))
    Can.LetDestruct pat x body ->
      do  x' <- specExpr se x
          pat' <- fitPat (mRep x') <$> specPat se pat
          b' <- specExpr se body
          return (MExpr (mRep b') (MCase x' [(pat', b')]))
    Can.VarCtor _ h name _ _
      | moduleChars h ++ "." ++ N.toChars name == "elm/core:Basics.True" -> return (MExpr CEnum (MLit (LInt 1)))      -- Bool is 0 or 1 in C
      | moduleChars h ++ "." ++ N.toChars name == "elm/core:Basics.False" -> return (MExpr CEnum (MLit (LInt 0)))
    Can.VarCtor {} -> specRef se region e
    Can.Call (A.At fregion f) args -> specCall se region e fregion f args
    Can.Binop _ h n _ l@(A.At lregion l') r@(A.At rregion r')
      | moduleChars h ++ "." ++ N.toChars n == "elm/core:Basics.apR" -> specCall se region e rregion r' [l]      -- x |> f is f x
      | moduleChars h ++ "." ++ N.toChars n == "elm/core:Basics.apL" -> specCall se region e lregion l' [r]      -- f <| x is f x
    Can.Binop _ _ _ _ l r -> specCall' se region e region e [l, r]
    Can.Lambda pats body -> specLambda se region pats body
    -- `.x` is the function \r -> r.x: a lifted lambda of its own, from the recorded type `{ a | x : t } -> t`
    Can.Accessor fld ->
      do  enums <- gets sEnums
          case nodeType se (Recorder.exprKey region e) of
            Just (TFun rt ft)
              | Just fl <- rowFieldsT enums (seEnv se) rt
              , Just i <- lookup (N.toChars fld) (zip (map fst fl) [0 :: Int ..]) ->
                  do  lamId <- freshId
                      fcls <- classOfTy se ft
                      let rcls = CStruct (map snd fl)
                          body = MExpr fcls (MAccess (MExpr rcls (MLocal "_r")) (N.toChars fld) i)
                      modify' (\st -> st { sDone = Map.insert lamId (MDef lamId ("." ++ N.toChars fld) (Key []) Function [("_r", rcls)] fcls (Just body) Nothing [] (Just (seClone se)) [] [] Nothing False) (sDone st) })
                      return (MExpr CRef (MGlobal lamId))
            _ -> unsupported "a field accessor on a record whose layout is not known" region
    Can.VarLocal _ -> specRef se region e
    Can.VarTopLevel _ _ -> specRef se region e
    Can.VarForeign {} -> specRef se region e
    Can.VarDebug {} -> specRef se region e
    Can.VarOperator {} -> specRef se region e
    Can.VarKernel home name
      | String.toChars (Module.kernelToString home) == Derive.kernelHome ->
          -- Ficcus (A4a): a derived member has a signature but no body yet
          do  report ("the derived member `" ++ Derive.stubDisplay name ++ "` (derive line at " ++ regionText region ++ ") is not generated yet: A4a checks the `derive` line and gives the member its type, the bodies come with A4b to A4f; a program that uses a derived member cannot be compiled to C before then")
              return unitLit
    Can.VarKernel home name -> unsupported ("the kernel function Elm.Kernel." ++ String.toChars (Module.kernelToString home) ++ "." ++ N.toChars name ++ " (it has no Elm body; the runtime table is Ficcus.Mono.Kernel)") region
    _ -> unsupported ("expression " ++ Recorder.exprKind e) region


-- a pattern with the classes of its parts
-- the result classes of kernel functions whose result type the recorder cannot give when the kernel is called directly in a package
-- body (`let (a, b, c) = Elm.Kernel.Parser.findSubString ...`: the pattern variables are generalized variables there)
overrideKernelClass :: String -> MExpr -> MExpr
overrideKernelClass name (MExpr c node) =
  MExpr (maybe c id (lookup name table)) node
  where
    table =
      [ ("elm/parser:Parser.Advanced.findSubString", CStruct [CI64, CI64, CI64]), ("elm/parser:Parser.Advanced.isSubString", CStruct [CI64, CI64, CI64])
      , ("elm/parser:Parser.Advanced.consumeBase", CStruct [CI64, CI64]), ("elm/parser:Parser.Advanced.consumeBase16", CStruct [CI64, CI64]) ]


-- a tuple pattern takes the classes of the struct it is matched against (the recorded types of its variables may be generalized variables)
fitPat :: Class -> MPat -> MPat
fitPat c p =
  case (c, mpNode p) of
    (CStruct fs, PTuple ps) | length fs == length ps -> MPat c (PTuple (zipWith fitPat fs ps))
    -- a boxed field (a record or tuple inside a tuple is a reference there) bound to a variable whose own class is the struct: the
    -- pattern compiler unboxes it (found by the V2 differential test: `let ( r, st1 ) = f x in ( r, st1 )` with a record `st1`)
    (CRef, PVar _) | CStruct _ <- mpRep p -> p
    (_, PVar n) -> MPat c (PVar n)
    (_, PWild) -> MPat c PWild
    (_, PAlias q n) -> MPat c (PAlias (fitPat c q) n)
    _ -> p


specPat :: SEnv -> Can.Pattern -> SM MPat
specPat se pat@(A.At region p) =
  do  cls <- patClass se pat
      let mk = return . MPat cls
      case p of
        Can.PAnything -> mk PWild
        Can.PVar n -> mk (PVar (N.toChars n))
        Can.PUnit -> mk PWild
        Can.PPair a b -> (\x y -> MPat cls (PTuple [x, y])) <$> specPat se a <*> specPat se b
        Can.PTriple a b c -> (\x y z -> MPat cls (PTuple [x, y, z])) <$> specPat se a <*> specPat se b <*> specPat se c
        Can.PAlias q n -> (\x -> MPat cls (PAlias x (N.toChars n))) <$> specPat se q
        Can.PRecord names ->
          do  let t = Map.lookup (Recorder.patKey region p) (_nodes (_typed (seCtx se)))
              -- E2: through aliases (`onEffects router subs {processes}` on `State msg`, elm/time's manager)
              case fmap strip t of
                Just (TRecord fs Nothing) ->
                  do  fields <- forM (zip [0 :: Int ..] (Map.toList fs)) $ \(i, (k, ft)) ->
                        if k `elem` names then (\c -> [(i, N.toChars k, c)]) <$> classOfTy se (applyDefault (\v -> not (Map.member v (seEnv se))) ft) else return []
                      mk (PRecord (concat fields))
                _ -> report ("a record pattern on an extensible record (row polymorphism: slice 5) at " ++ regionText region) >> mk PWild
        Can.PList ps -> foldr (\x acc -> do { x' <- specPat se x; a <- acc; return (MPat CRef (PCons x' a)) }) (return (MPat CRef PNil)) ps
        Can.PCons h t -> (\x y -> MPat cls (PCons x y)) <$> specPat se h <*> specPat se t
        Can.PBool _ b -> mk (PLit (LInt (if b then 1 else 0)))
        Can.PChr c -> mk (PLit (LChar (ord c)))
        Can.PStr s -> mk (PLit (LString (unescape (ES.toChars s))))
        Can.PInt n ->
          do  -- (ATTACH A3) a pattern is matched by the structure of the value: a number pattern at a custom type has no meaning
              custom <- customTypeOf se (Recorder.patKey region p)
              case custom of
                Just (TyCon tid _) -> report ("a number pattern at the type " ++ tid ++ " (it has fromInt, so a literal is a value of it, but a pattern cannot call a member; compare with == in an `if`), at " ++ regionText region) >> mk PWild
                _ -> mk (PLit (LInt (fromIntegral n)))
        Can.PCtor { Can._p_name = name, Can._p_index = idx, Can._p_args = cargs } ->
          do  args <- mapM (specPat se . Can._arg) cargs
              mk (PCtor (N.toChars name) (Index.toMachine idx) args)


-- `-x`: `neg` of a custom type (A3), the kernel of a sized type (SIZED), else Elm's `negate`
specNegate :: SEnv -> A.Region -> Can.Expr_ -> Can.Expr -> SM MExpr
specNegate se region e x =
  do  cls <- exprClass se region e
      x' <- specExpr se x
      key <- keyOfType se (nodeType se (Recorder.exprKey region e))
      sz <- sizedOfNode se (Recorder.exprKey region e)
      custom <- customTypeOf se (Recorder.exprKey region e)
      case custom of
        _ | Just s <- sz -> return (MExpr cls (MCall (MExpr CRef (MKernel (Sized.kernelId s "neg") (Key []))) [x']))
        -- (ATTACH A3) `-x` at a custom type is `neg x`
        Just t@(TyCon tid _) ->
          do  r <- memberClone tid "neg" (shapeType WK.Unary t)
              case r of
                Right (RClone c _ _) -> return (MExpr cls (MCall (MExpr CRef (MGlobal c)) [x']))
                Right _ -> report ("internal: neg of " ++ tid ++ " is not a function") >> return x'
                Left why -> report ("cannot specialize `-` at " ++ tid ++ ": " ++ why) >> return x'
        _ -> return (MExpr cls (MCall (MExpr CRef (MKernel "elm/core:Basics.negate" key)) [x']))


unsupported :: String -> A.Region -> SM MExpr
unsupported what region =
  do  report (what ++ " is not supported yet at " ++ regionText region)
      return unitLit


readDouble :: String -> Double
readDouble s =
  case reads (fixup s) of
    (x, "") : _ -> x
    _ -> 0
  where
    fixup str = case str of { '.' : _ -> '0' : str; _ -> str }


keyOfType :: SEnv -> Maybe TType -> SM Key
keyOfType se mt =
  case mtypeOf (seEnv se) (maybe TUnit id mt) of
    Right m -> return (Key [ByType m])
    Left why -> report ("cannot key an operator: " ++ why) >> return (Key [ByClass CRef])


-- a let: local functions are lifted clones, local values are bound in order
specLet :: SEnv -> [Can.Def] -> Bool -> Can.Expr -> SM MExpr
specLet se defs isRec body@(A.At bregion _) =
  do  let ctx' = bindDefs (seCtx se) isRec defs
      let me = seClone se
      let srcFor locals d = Src ctx' d (seEnv se) locals (Just me) (seMembers se)
      let isFun d = not (null (defArgs d)) || polyValue ctx' (seEnv se) d
      let funs = [ d | d <- defs, isFun d ]
      let locals' = Map.union (Map.fromList [ (defIdOf ctx' (defKeyOf d), srcFor locals' d) | d <- funs ]) (seLocals se)
      let se' = se { seCtx = ctx', seLocals = Map.union (Map.fromList [ (defIdOf ctx' (defKeyOf d), srcFor locals' d) | d <- defs, not (isFun d) ]) locals' }
      binds <- forM [ d | d <- defs, not (isFun d) ] $ \d ->
        do  v <- specExpr se' (defBody d)
            return (uniqLocal (defNameChars d) (defIdOf ctx' (defKeyOf d)), v)
      -- a polymorphic value (`let a = Debug.log "a" 1` is generalized over `number`) is evaluated once, where it is bound,
      -- like Elm's JavaScript value: the clones of the instances that the body uses become variables bound here
      let CloneId meK = me
      let hoistIds = [ (defIdOf ctx' (defKeyOf d), meK) | not isRec, [d] <- [defs], isFun d, null (defArgs d) ]
      modify' (\st -> st { sHoist = Set.union (Set.fromList hoistIds) (sHoist st) })
      b' <- specExpr se' body
      -- a polymorphic value that the body never uses is still evaluated (Elm evaluates it): one instance at the default
      -- type (`number` is Int), so that a `Debug.log` in it prints
      _ <- forM [ (h, d) | not isRec, [d] <- [defs], h <- hoistIds ] $ \(h, d) ->
        do  used <- gets (Map.findWithDefault Set.empty h . sHoisted)
            when (Set.null used) $
              case Map.lookup (defKeyOf d) (_defs (_typed ctx')) of
                Nothing -> return ()
                Just sch ->
                  do  let kinds = kindList sch
                      let isOuter n = Map.member n (seEnv se)
                      let own = [ (n, i) | (n, i) <- canonVars sch, not (isOuter n) ]
                      let sub = Map.fromList [ (n, defaultKind KNumber) | (n, i) <- own, i < length kinds, kinds !! i == "number" ]
                      let did = defIdOf ctx' (defKeyOf d)
                      key <- keyFor se' did sch sub isOuter
                      c <- requestClone (CKey did (Just me) key) (srcFor locals' d)
                      let CloneId k = c
                      modify' (\st -> st { sHoisted = Map.insertWith Set.union h (Set.singleton k) (sHoisted st) })
      -- the clones the body needs (local functions, lambdas, other polymorphic values) are generated now, while the
      -- window is open, so that their uses of the value are variables too
      when (not (null hoistIds)) drain
      modify' (\st -> st { sHoist = Set.difference (sHoist st) (Set.fromList hoistIds) })
      _ <- return bregion
      st <- gets id
      let pvs = [ k | h <- hoistIds, k <- Set.toList (Map.findWithDefault Set.empty h (sHoisted st)) ]
          bind k acc = MExpr (mRep acc) (MLetVal ("_pv" ++ show k) (MExpr (Map.findWithDefault (maybe CRef mdResult (Map.lookup (CloneId k) (sDone st))) ("_pv" ++ show k) (sPvClass st)) (MCall (MExpr CRef (MGlobal (CloneId k))) [])) acc)
      return (foldr bind (foldr (\(n, v) acc -> MExpr (mRep acc) (MLetVal n v acc)) b' binds) pvs)


-- the C name of a let bound value: its source name and the position of its definition (`n@15:9`), so that two lets of the same
-- name in one function (siblings, as in a list of `let n = .. in ..`) do not declare one variable twice
uniqLocal :: String -> String -> String
uniqLocal name did =
  case break (== '@') did of
    (_, '@' : pos) -> name ++ "@" ++ pos
    _ -> name


-- a local value with variables of its own (`let e = []` generalized): a lifted clone of no arguments per key,
-- evaluated at each use (a pure value, so the same result)
polyValue :: Ctx -> Env -> Can.Def -> Bool
polyValue ctx env d =
  null (defArgs d) &&
  case Map.lookup (defKeyOf d) (_defs (_typed ctx)) of
    Just sch -> not (null [ () | (n, _) <- canonVars sch, not (Map.member n env) ])
    Nothing -> False


defArgs :: Can.Def -> [Can.Pattern]
defArgs d =
  case d of
    Can.Def _ ps _ -> ps
    Can.TypedDef _ _ tps _ _ -> map fst tps


defBody :: Can.Def -> Can.Expr
defBody d =
  case d of
    Can.Def _ _ b -> b
    Can.TypedDef _ _ _ b _ -> b


-- what a name refers to
data Ref
  = RKernel String Key Int
  | RClone CloneId Int Bool            -- clone, arity, is a value
  | RLocal String                      -- parameter or local value
  | RCtor String Int Int               -- constructor name, tag, number of arguments
  | RRec [String]                      -- the constructor function of a record alias: the field names in argument order
  | RNone


-- a call: `f a b` where f is named (a clone, a kernel function, a constructor, a local) or computed
specCall :: SEnv -> A.Region -> Can.Expr_ -> A.Region -> Can.Expr_ -> [Can.Expr] -> SM MExpr
specCall se region resNode fregion f args =
  case f of
    Can.VarForeign _ _ _ | isWorker f -> specWorker se region fregion f args
    Can.Call (A.At gregion g) gargs -> specCall se region resNode gregion g (gargs ++ args)   -- (g a) b is g a b
    _ | isVarLike f -> specCall' se region resNode fregion f args
    _ ->
      do  cls <- exprClass se region resNode
          f' <- specExpr se (A.At fregion f)
          args' <- mapM (specExpr se) args
          return (MExpr cls (MCall f' args'))
  where
    isWorker (Can.VarForeign h n _) = moduleChars h ++ "." ++ N.toChars n == "elm/core:Platform.worker"
    isWorker _ = False


isVarLike :: Can.Expr_ -> Bool
isVarLike e =
  case e of
    Can.VarLocal _ -> True
    Can.VarTopLevel _ _ -> True
    Can.VarForeign {} -> True
    Can.VarDebug {} -> True
    Can.VarKernel {} -> True
    Can.VarOperator {} -> True
    Can.VarCtor {} -> True
    _ -> False                                      -- (a Binop is an expression of its own: `(f << g) x` is a computed call)


-- a call of a named function. With as many arguments as its arity it is a direct call; with fewer a partial
-- application (a lifted lambda that holds the arguments, `partialApp`); with more, a call with the first
-- ones and an unknown call of the result with the rest. A local variable is always an unknown call.
-- `resNode` is the node whose recorded type is the type of the whole expression.
specCall' :: SEnv -> A.Region -> Can.Expr_ -> A.Region -> Can.Expr_ -> [Can.Expr] -> SM MExpr
specCall' se region resNode fregion f args =
  do  ref <- resolve se fregion f
      args' <- mapM (specExpr se) args
      case ref of
        RKernel name key arity -> overrideKernelClass name <$> known arity (\as -> MCall (MExpr CRef (MKernel name key)) as) args'
        RClone c arity isVal -> known arity (cloneCall c isVal) args'
        RCtor name tag arity | arity > 0 -> known arity (\as -> MCall (MExpr CRef (MCtor name tag (Key [ ByClass (boxed (mRep a)) | a <- as ]))) as) args'
        RLocal n ->
          do  cls <- exprClass se region resNode
              hcls <- exprClass se fregion f
              return (MExpr cls (MCall (MExpr hcls (MLocal n)) args'))
        RRec names -> known (length names) (\as -> MRecord (List.sortOn (\(n, _) -> (length n, n)) (zip names as))) args'
        RNone -> return unitLit
        _ -> unsupported "a call of this kind of name" region
  where
    known arity mk args'
      | n == arity =
          do  cls <- exprClass se region resNode
              return (MExpr cls (mk args'))
      | n < arity = partialApp se region resNode (arity - n) mk args'
      | otherwise =
          -- an over-application is one call in Elm: every argument is evaluated, left to right, before the function runs
          do  cls <- exprClass se region resNode
              CloneId k <- freshId
              let names = [ "_oa" ++ show k ++ "_" ++ show i | i <- [0 .. n - 1] ]
                  locals = [ MExpr (mRep a) (MLocal t) | (t, a) <- zip names args' ]
                  (first, rest) = splitAt arity locals
                  call = MExpr cls (MCall (MExpr CRef (mk first)) rest)
              return (foldr (\(t, a) acc -> MExpr cls (MLetVal t a acc)) call (zip names args'))
      where n = length args'
    cloneCall c isVal as
      | null as = if isVal then MGlobal c else MCall (MExpr CRef (MGlobal c)) []
      | otherwise = MCall (MExpr CRef (MGlobal c)) as


-- a name used as a value (no arguments)
specRef :: SEnv -> A.Region -> Can.Expr_ -> SM MExpr
specRef se region e =
  do  ref <- resolve se region e
      cls <- exprClass se region e
      case ref of
        RKernel name key 0 -> return (MExpr cls (MKernel name key))
        RKernel name key arity -> partialApp se region e arity (\as -> MCall (MExpr CRef (MKernel name key)) as) []
        RClone c 0 True -> return (MExpr cls (MGlobal c))
        RClone c 0 False -> return (MExpr cls (MCall (MExpr CRef (MGlobal c)) []))
        RClone c _ _ -> return (MExpr CRef (MGlobal c))           -- a function used as a value: a closure (CGen)
        RLocal n ->
          do  when (take 3 n == "_pv") (modify' (\st -> st { sPvClass = Map.insert n cls (sPvClass st) }))
              return (MExpr cls (MLocal n))
        RCtor name tag 0 -> return (MExpr cls (MCtor name tag (Key [])))
        RCtor name tag arity -> partialApp se region e arity (\as -> MCall (MExpr CRef (MCtor name tag (Key [ ByClass (boxed (mRep a)) | a <- as ]))) as) []
        RRec [] -> return (MExpr cls (MRecord []))
        RRec names -> partialApp se region e (length names) (\as -> MRecord (List.sortOn (\(n, _) -> (length n, n)) (zip names as))) []
        RNone -> return unitLit


-- | a partial application `f a b` of a function that needs `remaining` more arguments: the arguments are
-- evaluated now and bound to locals, and a lifted lambda `\x y -> f a b x y` (a clone of its own; the locals
-- are its captured variables) is the value. The classes of the new parameters come from the recorded type
-- of the expression, which is a function type.
partialApp :: SEnv -> A.Region -> Can.Expr_ -> Int -> ([MExpr] -> MNode) -> [MExpr] -> SM MExpr
partialApp se region resNode remaining mk supplied =
  case nodeType se (Recorder.exprKey region resNode) >>= peelFun remaining of
    Nothing -> unsupported "a partial application whose type is not a function type" region
    Just (ptys, rty) ->
      do  pcls <- mapM (classOfTy se) ptys
          rcls <- classOfTy se rty
          lamId <- freshId
          let CloneId k = lamId
          let sup = [ ("_pa" ++ show k ++ "_" ++ show i, a) | (i, a) <- zip [0 :: Int ..] supplied ]
          let ps = [ ("_pb" ++ show k ++ "_" ++ show i, c) | (i, c) <- zip [0 :: Int ..] pcls ]
          let body = MExpr rcls (mk ([ MExpr (mRep a) (MLocal t) | (t, a) <- sup ] ++ [ MExpr c (MLocal p) | (p, c) <- ps ]))
          modify' (\st -> st { sDone = Map.insert lamId (MDef lamId (lambdaName se region) (Key []) Function ps rcls (Just body) Nothing [] (Just (seClone se)) [] [] Nothing False) (sDone st) })
          return (foldr (\(t, a) acc -> MExpr CRef (MLetVal t a acc)) (MExpr CRef (MGlobal lamId)) sup)


-- the id of a lifted lambda: like a local definition, the module and the position
lambdaName :: SEnv -> A.Region -> String
lambdaName se region =
  moduleChars (_home (seCtx se)) ++ ".lambda@" ++ map (\c -> if c == ':' then ':' else c) (takeWhile (/= '-') (regionText region))


-- the first n parameter types of a function type and what is left
peelFun :: Int -> TType -> Maybe ([TType], TType)
peelFun n t
  | n == 0 = Just ([], t)
  | otherwise =
      case t of
        TFun a b -> (\(as, r) -> (a : as, r)) <$> peelFun (n - 1) b
        TAlias _ _ _ real -> peelFun n real
        _ -> Nothing


-- | a lambda expression: a lifted clone of its own (its free variables are found by the code generator, as for
-- a local function) and the value is that clone used as a value
specLambda :: SEnv -> A.Region -> [Can.Pattern] -> Can.Expr -> SM MExpr
specLambda se region pats body =
  do  lamId <- freshId
      let se' = se { seClone = lamId }
      ps <- forM (zip [0 :: Int ..] pats) (param se')
      body0 <- specExpr se' body
      body' <- wrapParams se' (zip pats ps) body0
      modify' (\st -> st { sDone = Map.insert lamId (MDef lamId (lambdaName se region) (Key []) Function ps (mRep body') (Just body') Nothing [] (Just (seClone se)) [] [] Nothing False) (sDone st) })
      return (MExpr CRef (MGlobal lamId))


resolve :: SEnv -> A.Region -> Can.Expr_ -> SM Ref
resolve se region e =
  case e of
    Can.VarLocal name | Just ref <- Map.lookup (N.toChars name) (seMembers se) -> return ref      -- (ATTACH A2) the name of a constraint
    Can.VarLocal name ->
      case Map.lookup name (_vals ctx) of
        Just (Left key) ->
          let did = defIdOf ctx key
          in case Map.lookup did (seLocals se) of
               Just src | null (defArgs (srcDef src)) && not (polyValue (srcCtx src) (srcOuter src) (srcDef src)) -> return (RLocal (uniqLocal (N.toChars name) did))
               Just src | null (defArgs (srcDef src)) ->
                 do  r <- viaClone src did
                     act <- gets sHoist
                     let CloneId ownerK = maybe (CloneId (-1)) id (srcOwner src)
                     case r of
                       RClone (CloneId k) _ _ | Set.member (did, ownerK) act ->
                         do  modify' (\st -> st { sHoisted = Map.insertWith Set.union (did, ownerK) (Set.singleton k) (sHoisted st) })
                             return (RLocal ("_pv" ++ show k))
                       _ -> return r
               Just src -> viaClone src did
               Nothing -> report ("internal: local definition " ++ did ++ " is not in scope of the specializer") >> return RNone
        _ -> return (RLocal (N.toChars name))
    Can.VarTopLevel h n | N.toChars n `elem` ["command", "subscription"] ->
      do  mgrs <- gets sManagers
          tops <- gets sTops
          let home = moduleChars h
          let cid = home ++ "." ++ N.toChars n
          case (Map.lookup home mgrs, Map.member cid tops) of
            (Just _, False) -> leafRef home
            _ -> foreignOrTop cid
    Can.VarTopLevel h n ->
      do  ports <- gets sPorts
          case Map.lookup (moduleChars h ++ "." ++ N.toChars n) ports of
            Just isOut -> portRef isOut (N.toChars n)
            Nothing -> foreignOrTop (moduleChars h ++ "." ++ N.toChars n)
    Can.VarForeign h n _ -> foreignOrTop (moduleChars h ++ "." ++ N.toChars n)
    Can.VarOperator _ h n _ -> foreignOrTop (moduleChars h ++ "." ++ N.toChars n)
    Can.Binop _ h n _ _ _ -> foreignOrTop (moduleChars h ++ "." ++ N.toChars n)
    Can.VarDebug _ n _ -> foreignOrTop ("elm/core:Debug." ++ N.toChars n)
    -- `Elm.Kernel.Basics.log x` written directly in an elm/core body (logBase): a kernel function without variables
    Can.VarKernel home _ | String.toChars (Module.kernelToString home) == Derive.kernelHome -> return RNone    -- A4a: reported by spec
    Can.VarKernel home name ->
      let kmod = String.toChars (Module.kernelToString home)
      in case [ (cid, a) | cid <- directKernelIds kmod (N.toChars name), Just a <- [kernelArity cid] ] of
           (cid, arity) : _ -> return (RKernel cid (Key []) arity)
           [] -> report ("the kernel function Elm.Kernel." ++ kmod ++ "." ++ N.toChars name ++ " is not in the kernel table (Ficcus.Mono.Kernel), at " ++ regionText region) >> return RNone
    Can.VarCtor _ _ name idx (Can.Forall _ tipe) ->
      return (case recordCtor tipe of
                Just names -> RRec names
                Nothing -> RCtor (N.toChars name) (Index.toMachine idx) (arrows tipe))
    _ -> return RNone
  where
    ctx = seCtx se
    raw = Map.lookup (Recorder.exprKey region e) (_nodes (_typed ctx))

    -- E1 step 2: `command`/`subscription` of an effect module: the leaf kernel of its home, keyed by the class of `msg` at this use
    -- (`MyCmd msg -> Cmd msg`)
    leafRef home =
      case nodeType se (Recorder.exprKey region e) >>= peelFun 1 of
        Just (_, res) | Just m <- typeArg res ->
          do  c <- classOfTy se m
              modify' (\st -> st { sLeafHomes = Set.insert home (sLeafHomes st) })
              return (RKernel (leafKernelId home) (Key [ByClass (boxed c)]) 1)
        _ -> report ("internal: no type for the leaf of the effect manager " ++ home ++ " at " ++ regionText region) >> return RNone
    arrows t = case t of { Can.TLambda _ r -> 1 + arrows r; _ -> 0 :: Int }

    -- E2 step 7: a port is the leaf kernel of its manager, keyed by the payload type (`T -> Cmd msg`, `(T -> msg) -> Sub msg`)
    portRef isOut name =
      case nodeType se (Recorder.exprKey region e) >>= peelFun 1 of
        Just (p : _, _) ->
          let payload = if isOut then Just p else case strip p of { TFun a _ -> Just a; _ -> Nothing }
          in case fmap (mtypeOf (seEnv se)) payload of
               Just (Right m) -> return (RKernel (portKernelId isOut name) (Key [ByType m]) 1)
               _ -> report ("internal: no payload type for the port " ++ name ++ " at " ++ regionText region) >> return RNone
        _ -> report ("internal: no type for the port " ++ name ++ " at " ++ regionText region) >> return RNone

    -- `type alias P = { x : Int, y : Float }` makes a constructor function `P`: its result type is the alias,
    -- and the arguments are the fields in the order of the declaration (the field type carries the index)
    recordCtor t =
      case t of
        Can.TLambda _ r -> recordCtor r
        Can.TAlias _ _ _ (Can.Filled (Can.TRecord fields Nothing)) -> Just (fieldNames fields)
        Can.TAlias _ _ _ (Can.Holey (Can.TRecord fields Nothing)) -> Just (fieldNames fields)
        _ -> Nothing
    fieldNames fields = map (N.toChars . fst) (List.sortOn (\(_, Can.FieldType i _) -> i) (Map.toList fields))

    subst cid =
      case (calleeId ctx e, schemeInst) of
        (_, Nothing) -> report ("internal: no scheme for " ++ cid ++ " at " ++ regionText region) >> return Nothing
        (_, Just (scheme, inst)) ->
          case matchT scheme inst of
            Right s -> return (Just (scheme, s))
            Left why -> report ("internal: instance of " ++ cid ++ " does not match its scheme at " ++ regionText region ++ ": " ++ why) >> return Nothing

    schemeInst = raw >>= schemeOf ctx e

    -- (ATTACH A3) an operator at a custom type with the member behind it.  The instance type is defaulted as every node type is
    -- (`nodeType`): `compare (V [ 1 ]) (V [ 2 ])` has the instance `V number`, and the literals are Int (A3c, F7)
    foreignOrTop cid00 =
      do  let instD = fmap (applyDefault (\n -> not (Map.member n (seEnv se))) . snd) schemeInst
          hooked <- wellKnownRef se cid00 instD
          dtv <- wellKnownDerived se cid00 instD
          vsm <- vectorSortMember se cid00 instD
          tops1 <- gets sTops
          case (hooked, dtv >>= \o -> fmap (\src -> (o, src)) (Map.lookup o tops1)) of
            (Just ref, _) -> return ref
            (_, Just (o, src)) -> viaClone src o
            _ | Just (o, src) <- vsm >>= \o -> fmap (\src -> (o, src)) (Map.lookup o tops1) -> viaClone src o
            _ -> foreignOrTopPlain cid00

    foreignOrTopPlain cid00 =
      do  tops0 <- gets sTops
          vecOn <- gets sVector
          unionsNow <- gets sUnions
          -- Random.peel (decision L31): the Int product is rounded to a double like Elm's (JavaScript's) `*`, the fork's roundTo53
          let cid0 = if cid00 == "elm/core:Basics.mul" && "elm/random:Random.peel" `List.isPrefixOf` seDid se then "elm/core:Basics.mulRound53" else cid00
          -- a kernel function written in Elm in the overlay (Ficcus.Mono.Overlay) is an ordinary definition (the overlay's own
          -- calls of the function it replaces are not redirected)
          case (if randomOverlayPrefix `List.isPrefixOf` seDid se then Nothing else overlayId cid0) >>= \o -> fmap (\src -> (o, src)) (Map.lookup o tops0) of
            Just (o, src) -> viaClone src o
            Nothing
              -- the Bitwise64 module of the overlay: its functions are the kernel functions of the same name
              | Just n <- List.stripPrefix "author/project:Bitwise64." cid0, Map.member "author/project:Bitwise64.ficBitwise64Overlay" tops0 -> foreignOrTop' ("elm/core:Bitwise64." ++ n)
              -- SIZED: the conversions and bit operations of the module of a sized type are its kernels
              | Just (n, sz) <- sizedModuleFunction unionsNow cid0, Just op <- Sized.moduleFunctionOp sz n -> foreignOrTop' (Sized.kernelId sz op)
              -- the Vector module of the overlay (V1): the functions of its first section are the intrinsics of the same name
              | vecOn, Just n <- List.stripPrefix vectorModuleId cid0, n `elem` [ k | (k, _, _) <- vectorKernels ] -> foreignOrTop' (vectorKernelId n)
              | otherwise -> foreignOrTop' cid0

    foreignOrTop' cid =
      case kernelArity cid of
        Just arity ->
          do  ms <- subst cid
              case ms of
                Nothing -> return RNone
                Just (scheme, s) ->
                  do  key <- keyFor se cid scheme s (const False)
                      recordMapPair cid
                      return (RKernel cid key arity)
        Nothing ->
          do  tops <- gets sTops
              case Map.lookup cid tops of
                Nothing -> report ("`" ++ cid ++ "` has no definition and is not in the kernel table (at " ++ regionText region ++ ")") >> return RNone
                Just src -> viaClone src cid

    -- E1 step 2: the class pair (a, b) of a `Cmd.map`/`Sub.map` (`(a -> b) -> Cmd a -> Cmd b`): the managers' map functions are
    -- cloned at it
    recordMapPair cid =
      case mapKernelKind cid of
        Just isCmd | Just (TFun a b) <- fmap strip (nodeType se (Recorder.exprKey region e) >>= peelFun 1 >>= \(ps, _) -> case ps of { p : _ -> Just p; [] -> Nothing }) ->
          do  ca <- classOfTy se a
              cb <- classOfTy se b
              modify' (\st -> st { sMapPairs = Set.insert (isCmd, boxed ca, boxed cb) (sMapPairs st) })
        _ -> return ()

    viaClone src did =
      do  ms <- subst did
          case ms of
            Nothing -> return RNone
            Just (scheme, s) ->
              do  key <- keyFor se did scheme s (\n -> Map.member n (srcOuter src))
                  c <- requestClone (CKey did (srcOwner src) key) src
                  -- (ATTACH A2) the hidden parameters of a constrained definition are not arguments of its clones
                  let hiddenN = Constraints.hiddenCount (srcDef src)
                  return (RClone c (length (defArgs (srcDef src)) - hiddenN) (null (defArgs (srcDef src)) && srcOwner src == Nothing))


-- E1 STEP 3: THE PROGRAM'S UPDATE AND SUBSCRIPTIONS (docs/EFFECTS-DESIGN.md D-fx-3 amended)


-- | `update` and `subscriptions` of the worker become clones that the typed stepper of the C generator calls directly (the model as a
-- struct by value, never through a closure). They are appended to `main`'s worker call after `init`: `worker init update subscriptions`
-- (then the managers of step 2). Done after the first drain, so the clones of the rest of the program keep their ids (and names).
workerPhase :: String -> SM ()
workerPhase mainId =
  do  pending <- gets sWorkerFields
      case pending of
        Nothing -> return ()
        Just (se, u, sb) ->
          do  uc <- workerFn se "update" 2 u
              sc <- workerFn se "subscriptions" 1 sb
              drain
              clones <- gets sClones
              case Map.lookup (CKey mainId Nothing (Key [])) clones of
                Just r -> modify' (\st -> st { sDone = Map.adjust (appendWorkerArgs [MExpr CRef (MGlobal uc), MExpr CRef (MGlobal sc)]) r (sDone st) })
                Nothing -> return ()


-- | a field of the worker as a function clone of `arity` parameters: a lambda of that many parameters is a clone of its own (like
-- `init`); a top level function of that arity is its clone; anything else (`always Sub.none`, a lambda that returns a lambda) is a
-- clone that applies the value (a closure call, so the model goes through the word ABI: correct, without the D-fx-3 guarantee)
workerFn :: SEnv -> String -> Int -> Can.Expr -> SM CloneId
workerFn se name arity fieldExpr@(A.At region e) =
  case e of
    Can.Lambda pats body | length pats == arity ->
      do  fid <- freshId
          let se' = se { seClone = fid }
          ps <- forM (zip [0 :: Int ..] pats) (param se')
          body0 <- specExpr se' body
          body' <- wrapParams se' (zip pats ps) body0
          modify' (\st -> st { sDone = Map.insert fid (MDef fid name (Key []) Function ps (mRep body') (Just body') Nothing [] (Just (seClone se)) [] [] Nothing False) (sDone st) })
          return fid
    _ | isVarLike e ->
          do  ref <- resolve se region e
              case ref of
                RClone c n False | n == arity -> return c
                _ -> applied
    _ -> applied
  where
    applied =
      case nodeType se (Recorder.exprKey region e) >>= peelFun arity of
        Nothing -> report ("the `" ++ name ++ "` of Platform.worker is not a function of " ++ show arity ++ " arguments at " ++ regionText region) >> freshId
        Just (ptys, rty) ->
          do  fid <- freshId
              let se' = se { seClone = fid }
              pcls <- mapM (classOfTy se) ptys
              rcls <- classOfTy se rty
              f <- specExpr se' fieldExpr
              let ps = [ ("_w" ++ show i, c) | (i, c) <- zip [0 :: Int ..] pcls ]
              let body = MExpr rcls (MCall f [ MExpr c (MLocal p) | (p, c) <- ps ])
              modify' (\st -> st { sDone = Map.insert fid (MDef fid name (Key []) Function ps rcls (Just body) Nothing [] (Just (seClone se)) [] [] Nothing False) (sDone st) })
              return fid



-- E1 STEP 2: EFFECT MANAGERS (Ficcus.Mono.Effects)


-- | after the program is specialized: the managers whose leaves it uses are cloned (init, onEffects, onSelfMsg at the program's
-- `msg` class, cmdMap/subMap at every map pair), which can reach new leaves and map pairs, until nothing changes; then the table is
-- appended to the arguments of `main`'s worker call
managerPhase :: String -> SM ()
managerPhase mainId =
  do  appMsg <- gets sAppMsg
      case appMsg of
        Nothing -> return ()
        Just msgC -> loop msgC Nothing
  where
    loop msgC seen =
      do  homes <- gets sLeafHomes
          pairs <- gets sMapPairs
          if seen == Just (homes, pairs)
            then
              do  entries <- mapM (requestManager msgC pairs) (Set.toList homes)
                  clones <- gets sClones
                  case Map.lookup (CKey mainId Nothing (Key [])) clones of
                    Just r | not (null entries) -> modify' (\st -> st { sDone = Map.adjust (appendWorkerArgs entries) r (sDone st) })
                    _ -> return ()
            else
              do  mapM_ (requestManager msgC pairs) (Set.toList homes)
                  drain
                  loop msgC (Just (homes, pairs))


-- | the arguments added to `main`'s worker call (E1: managers in step 2, update and subscriptions in step 3)
appendWorkerArgs :: [MExpr] -> MDef -> MDef
appendWorkerArgs extra d =
  d { mdBody = fmap (\b -> case b of { MExpr c (MCall f args) -> MExpr c (MCall f (args ++ extra)); _ -> b }) (mdBody d) }


-- | the clones of one manager and its table entry `managerKernelId home (init, onEffects, onSelfMsg, cmdMaps.., subMaps..)`
requestManager :: Class -> Set.Set (Bool, Class, Class) -> String -> SM MExpr
requestManager msgC pairs home =
  do  mgrs <- gets sManagers
      let mg = Map.lookup home mgrs
      core <- mapM (\n -> managerClone (home ++ "." ++ n) (const (Just msgC))) ["init", "onEffects", "onSelfMsg"]
      cmdMaps <- if maybe True (\m -> mgCmd m == Nothing) mg then return [] else mapM (mapClone "cmdMap") [ (a, b) | (True, a, b) <- Set.toList pairs ]
      subMaps <- if maybe True (\m -> mgSub m == Nothing) mg then return [] else mapM (mapClone "subMap") [ (a, b) | (False, a, b) <- Set.toList pairs ]
      -- E2: the entry starts with two flags, whether the manager has commands and subscriptions (the arity of its onEffects)
      let flag b = MExpr CI64 (MLit (LInt (if b then 1 else 0)))
      return (MExpr CRef (MCall (MExpr CRef (MKernel (managerKernelId home) (Key [])))
                (flag (maybe False (\m -> mgCmd m /= Nothing) mg) : flag (maybe False (\m -> mgSub m /= Nothing) mg)
                   : [ MExpr CRef (MGlobal c) | Just c <- core ++ cmdMaps ++ subMaps ])))
  where
    -- `cmdMap : (a -> b) -> MyCmd a -> MyCmd b`: the variables of the tagger's argument and result
    mapClone n (ca, cb) =
      managerCloneWith (home ++ "." ++ n) $ \scheme v ->
        case strip scheme of
          TFun f _ | TFun (TVar va _ _) (TVar vb _ _) <- strip f -> if v == va then Just ca else if v == vb then Just cb else Nothing
          _ -> Nothing
    managerClone did classOf = managerCloneWith did (\_ v -> classOf v)
    managerCloneWith did classOf =
      do  tops <- gets sTops
          case Map.lookup did tops of
            Nothing -> report ("the effect manager " ++ home ++ " has no `" ++ did ++ "`") >> return Nothing
            Just src ->
              case Map.lookup (defKeyOf (srcDef src)) (_defs (_typed (srcCtx src))) of
                Nothing -> report ("no scheme recorded for " ++ did) >> return Nothing
                Just scheme ->
                  do  let kinds = kindList scheme
                      parts <- forM (canonVars scheme) $ \(v, i) ->
                        case classOf scheme v of
                          Just c | (if i < length kinds then kinds !! i else "any") == "any" -> return (ByClass (boxed c))
                          _ -> report ("cannot key the variable " ++ v ++ " of the effect manager function " ++ did) >> return (ByClass CRef)
                      fmap Just (requestClone (CKey did Nothing (Key parts)) src)


-- | the one type argument of a type (`Cmd msg`), through aliases
typeArg :: TType -> Maybe TType
typeArg t =
  case t of
    TCon _ _ [a] -> Just a
    TAlias _ _ _ real -> typeArg real
    _ -> Nothing



-- Platform.worker { init = \flags -> ..., ... }: the init lambda becomes a clone of its own; update and
-- subscriptions are never run (commands are ignored, STAGE3-PLAN R9)
specWorker :: SEnv -> A.Region -> A.Region -> Can.Expr_ -> [Can.Expr] -> SM MExpr
specWorker se region fregion f args =
  case args of
    [A.At _ (Can.Record fields)] | [A.At _ (Can.Lambda [pat] body)] <- [ x | (k, x) <- Map.toList fields, N.toChars k == "init" ] ->
      do  _ <- return fregion
          let call = Can.Call (A.At fregion f) args
          cls <- exprClass se region call
          -- E1 step 2: the class of the program's `msg` (`Program flags model msg`), the key of the effect managers
          case fmap strip (nodeType se (Recorder.exprKey region call)) of
            Just (TCon _ _ [_, _, msgT]) | not noStepper ->
              do  mc <- classOfTy se msgT
                  modify' (\st -> st { sAppMsg = Just (boxed mc) })
            _ -> return ()
          -- E2 review fix 1: flags other than () would reach init as a 0 word (Int: silently 0, String: a crash); refused until E3
          case fmap strip (nodeType se (Recorder.exprKey region call)) of
            Just (TCon _ _ [flagsT, _, _]) | not (unitFlags flagsT) ->
              report ("main is a Platform.worker with flags (`Program flags model msg` with flags other than `()`): flags are not supported yet"
                      ++ " (they come with effects slice E3) at " ++ regionText region)
            _ -> return ()
          key <- do ref <- resolve se fregion f
                    return (case ref of { RKernel _ k _ -> k; _ -> Key [] })
          -- E1 step 3: update and subscriptions are cloned after the rest of the program (`workerPhase`: the existing clones keep their ids)
          case ([ x | (k, x) <- Map.toList fields, N.toChars k == "update" ], [ x | (k, x) <- Map.toList fields, N.toChars k == "subscriptions" ]) of
            ([u], [sb]) | not noStepper -> modify' (\st -> st { sWorkerFields = Just (se, u, sb) })
            _ -> return ()
          initId <- freshId
          p <- param se (0, pat)
          body' <- specExpr (se { seClone = initId }) body
          let def = MDef initId "init" (Key []) Function [p] (mRep body') (Just body') Nothing [] (Just (seClone se)) [] [] Nothing False
          modify' (\s -> s { sDone = Map.insert initId def (sDone s) })
          return (MExpr cls (MCall (MExpr CRef (MKernel "elm/core:Platform.worker" key)) [MExpr CRef (MGlobal initId)]))
    _ -> unsupported "Platform.worker without a literal record with an `init` lambda" region


-- | flags the worker can run without: `()`, or a free variable (no value is ever decoded)
unitFlags :: TType -> Bool
unitFlags t = case t of { TUnit -> True; TVar _ _ _ -> True; _ -> False }


-- Elm.String holds a string literal as JavaScript source text: `\u0022` for a quote, `\u005C` for a backslash,
-- `\u000A` for a newline, surrogate pairs for code points above 0xFFFF. This gives the characters themselves.
unescape :: String -> String
unescape str =
  case str of
    '\\' : 'u' : a : b : c : d : rest | all isHex [a, b, c, d] ->
      let hi = hexValue [a, b, c, d]
      in case rest of
           -- Elm 0.19.3 writes the literal \u{FFFF} as the pair D7FF DFFF (its surrogate arithmetic is off by one at 0xFFFF):
           -- that is the one code point U+FFFF (reported, the JS output of the lexer is not changed)
           '\\' : 'u' : 'D' : 'F' : 'F' : 'F' : rest2 | hi == 0xD7FF -> '\xFFFF' : unescape rest2
           '\\' : 'u' : e : f : g : h : rest2
             | hi >= 0xD800 && hi < 0xDC00, all isHex [e, f, g, h], lo <- hexValue [e, f, g, h], lo >= 0xDC00 && lo < 0xE000 ->
                 toEnum (0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00)) : unescape rest2
           _ -> toEnum hi : unescape rest
    '\\' : 'n' : rest -> '\n' : unescape rest
    '\\' : 'r' : rest -> '\r' : unescape rest
    '\\' : 't' : rest -> '\t' : unescape rest
    '\\' : c : rest | c `elem` "\\\"'" -> c : unescape rest
    c : rest -> c : unescape rest
    [] -> []
  where
    isHex c = c `elem` "0123456789abcdefABCDEF"
    hexValue = foldl (\acc c -> acc * 16 + digit c) 0
    digit c
      | c >= '0' && c <= '9' = ord c - 48
      | c >= 'a' && c <= 'f' = ord c - 87
      | otherwise = ord c - 55

