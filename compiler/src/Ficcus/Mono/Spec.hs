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
import qualified Data.Index as Index
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import qualified Data.Set as Set

import qualified AST.Canonical as Can
import qualified AST.Prim.Module as Module
import qualified String
import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeName as T
import qualified Elm.Float as EF
import qualified Elm.String as ES
import Ficcus.Mono.Class
import Ficcus.Mono.Ir
import Ficcus.Mono.Kernel
import Ficcus.Mono.Overlay (overlayId, randomOverlayPrefix)
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
    }


type SM a = State S a


data SEnv =
  SEnv
    { seCtx :: Ctx
    , seEnv :: Env
    , seLocals :: Map.Map String Src
    , seClone :: CloneId
    , seDid :: String        -- the id of the definition being specialized
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
        tops = Map.fromList [ (defIdOf (mmCtx m') (defKeyOf d'), Src (mmCtx m') d' Map.empty Map.empty Nothing) | m' <- modules, d' <- mmDefs m' ]
        enums = Map.fromList (concatMap mmEnums modules)
        start = S 0 Map.empty Map.empty Seq.empty Map.empty [] marks tops enums Set.empty Map.empty Map.empty
        mainId = defIdOf (mmCtx m) (defKeyOf d)
        final = execState (requestRoot mainId >>= \r0 -> drain >> return r0) start
        root = Map.lookup (CKey mainId Nothing (Key [])) (sClones final)
      in
      case (reverse (sErrors final), root) of
        ([], Just r) -> Right (MProgram (ordered (sDone final) r) (Just r) (Map.fromList (concatMap mmUnions modules)))
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
      let se = SEnv ctx env (srcLocals src) cid did
      params <- forM (zip [0 :: Int ..] args) (param se)
      body0 <- specExpr se body
      body' <- wrapParams se (zip args params) body0
      return MDef
        { mdClone = cid, mdName = did, mdKey = key
        , mdKind = if null args && srcOwner src == Nothing then Value else Function
        , mdParams = params, mdResult = mRep body', mdBody = Just body'
        , mdInit = Nothing, mdNeeds = [], mdLifted = srcOwner src, mdVars = map snd ownIx, mdOwn = [], mdTwin = Nothing, mdCapsOwned = False }


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
      return (classOfT enums (seEnv se) t)


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
    "elm/core:Platform.Cmd.Cmd" -> CUnit       -- commands are ignored by Platform.worker (STAGE3-PLAN R9)
    "elm/core:Platform.Sub.Sub" -> CUnit
    "elm/core:Platform.Program" -> CUnit
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
                    case rowFieldsT enums env t of
                      Just fl -> return (ByLayout fl)
                      Nothing -> report ("cannot key the row variable v" ++ show i ++ " of " ++ cid) >> return (ByLayout [])
                | kind `elem` ["number", "comparable", "compappend"] || marked ->
                    case mtypeOf env t of
                      Right m | typeSizeUpTo typeSizeLimit m >= typeSizeLimit -> report (growthMessage cid) >> return (ByType (TyCon "ref" []))
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
              case t of
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
        Can.PInt n -> mk (PLit (LInt (fromIntegral n)))
        Can.PCtor { Can._p_name = name, Can._p_index = idx, Can._p_args = cargs } ->
          do  args <- mapM (specPat se . Can._arg) cargs
              mk (PCtor (N.toChars name) (Index.toMachine idx) args)


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
    Can.VarTopLevel h n -> foreignOrTop (moduleChars h ++ "." ++ N.toChars n)
    Can.VarForeign h n _ -> foreignOrTop (moduleChars h ++ "." ++ N.toChars n)
    Can.VarOperator _ h n _ -> foreignOrTop (moduleChars h ++ "." ++ N.toChars n)
    Can.Binop _ h n _ _ _ -> foreignOrTop (moduleChars h ++ "." ++ N.toChars n)
    Can.VarDebug _ n _ -> foreignOrTop ("elm/core:Debug." ++ N.toChars n)
    -- `Elm.Kernel.Basics.log x` written directly in an elm/core body (logBase): a kernel function without variables
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
    arrows t = case t of { Can.TLambda _ r -> 1 + arrows r; _ -> 0 :: Int }

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

    foreignOrTop cid00 =
      do  tops0 <- gets sTops
          -- Random.peel (decision L31): the Int product is rounded to a double like Elm's (JavaScript's) `*`, the fork's roundTo53
          let cid0 = if cid00 == "elm/core:Basics.mul" && "elm/random:Random.peel" `List.isPrefixOf` seDid se then "elm/core:Basics.mulRound53" else cid00
          -- a kernel function written in Elm in the overlay (Ficcus.Mono.Overlay) is an ordinary definition (the overlay's own
          -- calls of the function it replaces are not redirected)
          case (if randomOverlayPrefix `List.isPrefixOf` seDid se then Nothing else overlayId cid0) >>= \o -> fmap (\src -> (o, src)) (Map.lookup o tops0) of
            Just (o, src) -> viaClone src o
            Nothing
              -- the Bitwise64 module of the overlay: its functions are the kernel functions of the same name
              | Just n <- List.stripPrefix "author/project:Bitwise64." cid0 -> foreignOrTop' ("elm/core:Bitwise64." ++ n)
              | otherwise -> foreignOrTop' cid0

    foreignOrTop' cid =
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
                  return (RClone c (length (defArgs (srcDef src))) (null (defArgs (srcDef src)) && srcOwner src == Nothing))


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
          let def = MDef initId "init" (Key []) Function [p] (mRep body') (Just body') Nothing [] (Just (seClone se)) [] [] Nothing False
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
