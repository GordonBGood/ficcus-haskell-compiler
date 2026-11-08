{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE PatternGuards #-}
module Ficcus.Mono.Spec
  ( specialize
  , keyLimit
  , limitMessage
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


import Control.Monad (forM, when)
import Control.Monad.State.Strict (State, execState, gets, modify')
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Char (ord)
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import qualified Data.Set as Set

import qualified AST.Canonical as Can
import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeName as T
import qualified Elm.Float as EF
import qualified Elm.String as ES
import Ficcus.Mono.Class
import Ficcus.Mono.Ir
import Ficcus.Mono.Kernel
import Ficcus.Mono.Marks (Marks)
import qualified Ficcus.Mono.Marks as Marks
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
  ++ keyText key ++ "). It is called at types that keep growing."



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
    }


type SM a = State S a


data SEnv =
  SEnv
    { seCtx :: Ctx
    , seEnv :: Env
    , seLocals :: Map.Map String Src
    , seClone :: CloneId
    }


report :: String -> SM ()
report msg =
  modify' (\s -> s { sErrors = msg : sErrors s })


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
        tops = Map.fromList [ (defIdOf (mmCtx m') (defKeyOf d'), Src (mmCtx m') d' Map.empty Map.empty Nothing) | m' <- modules, d' <- mmDefs m' ]
        enums = Map.fromList (concatMap mmEnums modules)
        start = S 0 Map.empty Map.empty Seq.empty Map.empty [] marks tops enums
        mainId = defIdOf (mmCtx m) (defKeyOf d)
        final = execState (requestRoot mainId >>= \r0 -> drain >> return r0) start
        root = Map.lookup (CKey mainId Nothing (Key [])) (sClones final)
      in
      case (reverse (sErrors final), root) of
        ([], Just r) -> Right (MProgram (ordered (sDone final) r) (Just r))
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


-- | dependencies first: the clones in the order a depth first walk from the root finishes them
ordered :: Map.Map CloneId MDef -> CloneId -> [MDef]
ordered done root =
  reverse (snd (visit (Set.empty, []) root))
  where
    visit (seen, acc) c
      | Set.member c seen = (seen, acc)
      | otherwise =
          case Map.lookup c done of
            Nothing -> (Set.insert c seen, acc)
            Just d ->
              let (seen', acc') = foldl visit (Set.insert c seen, acc) (maybe [] exprRefs (mdBody d))
              in (seen', d : acc')


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
      let se = SEnv ctx env (srcLocals src) cid
      params <- forM (zip [0 :: Int ..] args) (param se)
      body' <- specExpr se body
      return MDef
        { mdClone = cid, mdName = did, mdKey = key
        , mdKind = if null args then Value else Function
        , mdParams = params, mdResult = mRep body', mdBody = Just body'
        , mdInit = Nothing, mdNeeds = [], mdLifted = srcOwner src, mdVars = map snd ownIx }


param :: SEnv -> (Int, Can.Pattern) -> SM (String, Class)
param se (i, pat@(A.At region p)) =
  do  cls <- patClass se pat
      case p of
        Can.PVar n -> return (N.toChars n, cls)
        Can.PAnything -> return ("_a" ++ show i, cls)
        _ ->
          do  report ("pattern parameter not supported yet (slice 3a) at " ++ regionText region)
              return ("_a" ++ show i, cls)


patClass :: SEnv -> Can.Pattern -> SM Class
patClass se (A.At region p) =
  case Map.lookup (Recorder.patKey region p) (_nodes (_typed (seCtx se))) of
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
      return (classOfT enums (seEnv se) t)


classOfT :: Map.Map String Bool -> Env -> TType -> Class
classOfT enums env t =
  case t of
    TCon h n args ->
      let name = moduleChars h ++ "." ++ N.toChars (T.nameToName n)
      in classOfName enums name (length args)
    TFun _ _ -> CRef
    TUnit -> CUnit
    TPair a b -> CStruct [go a, go b]
    TTriple a b c -> CStruct [go a, go b, go c]
    TRecord fields Nothing -> CStruct (map go (Map.elems fields))
    TRecord _ (Just _) -> CRef
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


classOfName :: Map.Map String Bool -> String -> Int -> Class
classOfName enums name _ =
  case name of
    "elm/core:Basics.Int" -> CI64
    "elm/core:Basics.Float" -> CF64
    "elm/core:Char.Char" -> CU32
    "elm/core:Basics.Bool" -> CEnum
    "elm/core:String.String" -> CRef         -- declared as a one constructor type in elm/core, but a built-in
    "elm/core:List.List" -> CRef
    "elm/core:Platform.Cmd.Cmd" -> CUnit       -- commands are ignored by Platform.worker (STAGE3-PLAN R9)
    "elm/core:Platform.Sub.Sub" -> CUnit
    "elm/core:Platform.Program" -> CUnit
    _ -> case Map.lookup name enums of { Just True -> CEnum; _ -> CRef }


classOfM :: Map.Map String Bool -> MType -> Class
classOfM enums t =
  case t of
    TyCon n args -> classOfName enums n (length args)
    TyFun _ _ -> CRef
    TyRecord fs -> CStruct [ classOfM enums x | (_, x) <- fs ]
    TyTuple xs -> CStruct (map (classOfM enums) xs)
    TyUnit -> CUnit


-- a struct that reaches an unconstrained variable is boxed (STAGE3-DESIGN section 0)
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
    TVar n _ _ ->
      case Map.lookup n env of
        Just (ByType m) -> Right m
        Just _ -> Left ("the variable " ++ n ++ " is used at an exact type but is keyed by class")
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
                    report ("row polymorphism is not supported yet (slice 5): " ++ cid) >> return (ByClass CRef)
                | kind `elem` ["number", "comparable", "compappend"] || marked ->
                    case mtypeOf env t of
                      Right m -> return (ByType m)
                      Left why -> report ("cannot key " ++ cid ++ " v" ++ show i ++ ": " ++ why) >> return (ByClass CRef)
                | kind == "appendable" -> return (ByApp (appClassOf enums env t))
                | otherwise -> return (ByClass (boxed (classOfT enums env t)))
      return (Key parts)


-- EXPRESSIONS


unitLit :: MExpr
unitLit = MExpr CUnit (MLit LUnit)


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
          return (MExpr cls (MLit (if cls == CF64 then LFloat (fromIntegral n) else LInt (fromIntegral n))))
    Can.Float f ->
      return (MExpr CF64 (MLit (LFloat (readDouble (BLC.unpack (BB.toLazyByteString (EF.toBuilder f)))))))
    Can.Unit -> return unitLit
    Can.Negate x ->
      do  cls <- exprClass se region e
          x' <- specExpr se x
          key <- keyOfType se (nodeType se (Recorder.exprKey region e))
          return (MExpr cls (MCall (MExpr CRef (MKernel "elm/core:Basics.negate" key)) [x']))
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
    Can.Call (A.At fregion f) args -> specCall se region fregion f args
    Can.Binop _ _ _ _ l r -> specCall' se region region e [l, r]
    Can.VarLocal _ -> specRef se region e
    Can.VarTopLevel _ _ -> specRef se region e
    Can.VarForeign {} -> specRef se region e
    Can.VarDebug {} -> specRef se region e
    Can.VarOperator {} -> specRef se region e
    _ -> unsupported ("expression " ++ Recorder.exprKind e) region


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
      let srcFor locals d = Src ctx' d (seEnv se) locals (Just me)
      let funs = [ d | d <- defs, not (null (defArgs d)) ]
      let locals' = Map.union (Map.fromList [ (defIdOf ctx' (defKeyOf d), srcFor locals' d) | d <- funs ]) (seLocals se)
      let se' = se { seCtx = ctx', seLocals = Map.union (Map.fromList [ (defIdOf ctx' (defKeyOf d), srcFor locals' d) | d <- defs, null (defArgs d) ]) locals' }
      binds <- forM [ d | d <- defs, null (defArgs d) ] $ \d ->
        do  let scheme = Map.lookup (defKeyOf d) (_defs (_typed ctx'))
            case scheme of
              Just sch | not (null [ () | (n, _) <- canonVars sch, not (Map.member n (seEnv se)) ]) ->
                report ("a polymorphic local value is not supported yet (slice 3a): " ++ defNameChars d)
              _ -> return ()
            v <- specExpr se' (defBody d)
            return (defNameChars d, v)
      b' <- specExpr se' body
      _ <- return bregion
      return (foldr (\(n, v) acc -> MExpr (mRep acc) (MLetVal n v acc)) b' binds)


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
  | RNone


specCall :: SEnv -> A.Region -> A.Region -> Can.Expr_ -> [Can.Expr] -> SM MExpr
specCall se region fregion f args =
  case f of
    Can.VarForeign _ _ _ | isWorker f ->
      specWorker se region fregion f args
    _ | isVarLike f -> specCall' se region fregion f args
    _ -> unsupported "calling a computed function (closure)" region
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
    Can.VarOperator {} -> True
    Can.Binop {} -> True
    _ -> False


-- a call of a named function with all its arguments
specCall' :: SEnv -> A.Region -> A.Region -> Can.Expr_ -> [Can.Expr] -> SM MExpr
specCall' se region fregion f args =
  do  cls <- exprClass se region (callNodeOf f args)
      ref <- resolve se fregion f
      args' <- mapM (specExpr se) args
      case ref of
        RKernel name key arity | arity == length args' -> return (MExpr cls (MCall (MExpr CRef (MKernel name key)) args'))
        RClone c arity _ | arity == length args' -> return (MExpr cls (MCall (MExpr CRef (MGlobal c)) args'))
        RNone -> return unitLit
        _ -> unsupported "a partial or over-applied call (closure)" region
  where
    -- the node whose recorded type is the result: the Binop itself, otherwise the Call node (same region as the call)
    callNodeOf _ _ = case f of { Can.Binop {} -> f; _ -> Can.Call (A.At region f) args }


-- a name used as a value (no arguments)
specRef :: SEnv -> A.Region -> Can.Expr_ -> SM MExpr
specRef se region e =
  do  ref <- resolve se region e
      cls <- exprClass se region e
      case ref of
        RKernel name key 0 -> return (MExpr cls (MKernel name key))
        RClone c 0 True -> return (MExpr cls (MGlobal c))
        RLocal n -> return (MExpr cls (MLocal n))
        RNone -> return unitLit
        _ -> unsupported "a function used as a value (closure)" region


resolve :: SEnv -> A.Region -> Can.Expr_ -> SM Ref
resolve se region e =
  case e of
    Can.VarLocal name ->
      case Map.lookup name (_vals ctx) of
        Just (Left key) ->
          let did = defIdOf ctx key
          in case Map.lookup did (seLocals se) of
               Just src | null (defArgs (srcDef src)) -> return (RLocal (N.toChars name))
               Just src -> viaClone src did
               Nothing -> report ("internal: local definition " ++ did ++ " is not in scope of the specializer") >> return RNone
        _ -> return (RLocal (N.toChars name))
    Can.VarTopLevel h n -> foreignOrTop (moduleChars h ++ "." ++ N.toChars n)
    Can.VarForeign h n _ -> foreignOrTop (moduleChars h ++ "." ++ N.toChars n)
    Can.VarOperator _ h n _ -> foreignOrTop (moduleChars h ++ "." ++ N.toChars n)
    Can.Binop _ h n _ _ _ -> foreignOrTop (moduleChars h ++ "." ++ N.toChars n)
    Can.VarDebug _ n _ -> foreignOrTop ("elm/core:Debug." ++ N.toChars n)
    Can.VarCtor {} -> report ("constructors are not supported yet (slice 3a) at " ++ regionText region) >> return RNone
    _ -> return RNone
  where
    ctx = seCtx se
    raw = Map.lookup (Recorder.exprKey region e) (_nodes (_typed ctx))

    subst cid =
      case (calleeId ctx e, schemeInst) of
        (_, Nothing) -> report ("internal: no scheme for " ++ cid ++ " at " ++ regionText region) >> return Nothing
        (_, Just (scheme, inst)) ->
          case matchT scheme inst of
            Right s -> return (Just (scheme, s))
            Left why -> report ("internal: instance of " ++ cid ++ " does not match its scheme at " ++ regionText region ++ ": " ++ why) >> return Nothing

    schemeInst = raw >>= schemeOf ctx e

    foreignOrTop cid =
      case kernelArity cid of
        Just arity ->
          do  ms <- subst cid
              case ms of
                Nothing -> return RNone
                Just (scheme, s) ->
                  do  key <- keyFor se cid scheme s (const False)
                      return (RKernel cid key arity)
        Nothing ->
          do  tops <- gets sTops
              case Map.lookup cid tops of
                Nothing -> report ("`" ++ cid ++ "` has no definition and is not in the kernel table (at " ++ regionText region ++ ")") >> return RNone
                Just src -> viaClone src cid

    viaClone src did =
      do  ms <- subst did
          case ms of
            Nothing -> return RNone
            Just (scheme, s) ->
              do  key <- keyFor se did scheme s (\n -> Map.member n (srcOuter src))
                  c <- requestClone (CKey did (srcOwner src) key) src
                  return (RClone c (length (defArgs (srcDef src))) (null (defArgs (srcDef src))))


-- Platform.worker { init = \flags -> ..., ... }: the init lambda becomes a clone of its own; update and
-- subscriptions are never run (commands are ignored, STAGE3-PLAN R9)
specWorker :: SEnv -> A.Region -> A.Region -> Can.Expr_ -> [Can.Expr] -> SM MExpr
specWorker se region fregion f args =
  case args of
    [A.At _ (Can.Record fields)] | [A.At _ (Can.Lambda [pat] body)] <- [ x | (k, x) <- Map.toList fields, N.toChars k == "init" ] ->
      do  _ <- return fregion
          cls <- exprClass se region (Can.Call (A.At fregion f) args)
          key <- do ref <- resolve se fregion f
                    return (case ref of { RKernel _ k _ -> k; _ -> Key [] })
          initId <- freshId
          p <- param se (0, pat)
          body' <- specExpr (se { seClone = initId }) body
          let def = MDef initId "init" (Key []) Function [p] (mRep body') (Just body') Nothing [] (Just (seClone se)) []
          modify' (\s -> s { sDone = Map.insert initId def (sDone s) })
          return (MExpr cls (MCall (MExpr CRef (MKernel "elm/core:Platform.worker" key)) [MExpr CRef (MGlobal initId)]))
    _ -> unsupported "Platform.worker without a literal record with an `init` lambda" region


-- Elm.String holds a string literal as JavaScript source text: `\u0022` for a quote, `\u005C` for a backslash,
-- `\u000A` for a newline, surrogate pairs for code points above 0xFFFF. This gives the characters themselves.
unescape :: String -> String
unescape str =
  case str of
    '\\' : 'u' : a : b : c : d : rest | all isHex [a, b, c, d] ->
      let hi = hexValue [a, b, c, d]
      in case rest of
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
