module Type.Constrain.Expression
  ( Env(..)
  , RTV
  , constrain
  , constrainDef
  , constrainRecursiveDefs
  )
  where


import qualified Data.Map.Strict as Map

import qualified AST.Canonical as Can
import qualified AST.Prim.Name as N
import qualified AST.Prim.Operator as Op
import qualified AST.Prim.TypeName as T
import qualified AST.Prim.TypeVar as T
import qualified AST.Utils.Shader as Shader
import qualified AST.Constraints as Constraints
import qualified Data.Maybe as Maybe
import qualified Data.Index as Index
import qualified Elm.ModuleName as ModuleName
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Type as E
import Reporting.Error.Type (Expected(..), Context(..), SubContext(..), MaybeName(..), Category(..), PExpected(..), PContext(..))
import qualified Type.Constrain.Pattern as Pattern
import qualified Type.Instantiate as Instantiate
import qualified Type.Recorder as Recorder
import Type.Type as Type hiding (Descriptor(..))



-- CONSTRAIN


-- As we step past type annotations, the free type variables are added to
-- the "rigid type variables" dict. Allowing sharing of rigid variables
-- between nested type annotations.
--
-- So if you have a top-level type annotation like (func : a -> b) the RTV
-- dictionary will hold variables for `a` and `b`
--
type RTV =
  Map.Map T.Var Type


-- Ficcus: the rigid variables plus, in typed mode, the type recorder.
-- Without a recorder (Nothing, JavaScript output) constraints are exactly the
-- ones Elm generates.
data Env =
  Env
    { _rtv :: RTV
    , _recorder :: Maybe Recorder.Recorder
    }


-- In typed mode every recorded node gets a flex variable that is made equal to
-- the type the parent expects of the node. The equation cannot fail, so the
-- verdict of the type checker is unchanged. See docs/TYPED-IR-DESIGN.md.
constrain :: Env -> Can.Expr -> Expected Type -> IO Constraint
constrain env (A.At region expression) expected =
  do  con <- constrainHelp env region expression expected
      case _recorder env of
        Nothing ->
          return con

        Just recorder ->
          if not (Recorder.isRecordedExpr expression)
            then return con
            else
              do  var <- mkFlexVar
                  Recorder.recordExpr recorder region expression var
                  return $ exists [var] $
                    CAnd [ con, CEqual region Unit (VarN var) (NoExpectation (expectedType expected)) ]


expectedType :: Expected Type -> Type
expectedType expected =
  case expected of
    NoExpectation tipe -> tipe
    FromContext _ _ tipe -> tipe
    FromAnnotation _ _ _ tipe -> tipe


constrainHelp :: Env -> A.Region -> Can.Expr_ -> Expected Type -> IO Constraint
constrainHelp env region expression expected =
  case expression of
    Can.VarLocal name ->
      return (CLocal region name expected)

    Can.VarTopLevel _ name ->
      return (CLocal region name expected)

    Can.VarKernel _ _ ->
      return CTrue

    Can.VarForeign _ name annotation ->
      return $ CForeign region name annotation expected

    Can.VarCtor _ _ name _ annotation ->
      return $ CForeign region name annotation expected

    Can.VarDebug _ name annotation ->
      return $ CForeign region name annotation expected

    Can.VarOperator op _ _ annotation ->
      return $ COperator region op annotation expected

    Can.Str _ ->
      return $ CEqual region String Type.string expected

    Can.Chr _ ->
      return $ CEqual region Char Type.char expected

    Can.Int _ ->
      do  var <- mkFlexNumber
          return $ exists [var] $ CEqual region E.Number (VarN var) expected

    Can.Float _ ->
      return $ CEqual region Float Type.float expected

    Can.List elements ->
      constrainList env region elements expected

    Can.Negate expr ->
      do  numberVar <- mkFlexNumber
          let numberType = VarN numberVar
          numberCon <- constrain env expr (FromContext region Negate numberType)
          let negateCon = CEqual region E.Number numberType expected
          return $ exists [numberVar] $ CAnd [ numberCon, negateCon ]

    Can.Binop op _ _ annotation leftExpr rightExpr ->
      constrainBinop env region op annotation leftExpr rightExpr expected

    Can.Lambda args body ->
      constrainLambda env region args body expected

    Can.Call func args ->
      constrainCall env region func args expected

    Can.If branches finally ->
      constrainIf env region branches finally expected

    Can.Case expr branches ->
      constrainCase env region expr branches expected

    Can.Let def body ->
      constrainDef env def
      =<< constrain env body expected

    Can.LetRec defs body ->
      constrainRecursiveDefs env defs
      =<< constrain env body expected

    Can.LetDestruct pattern expr body ->
      constrainDestruct env region pattern expr
      =<< constrain env body expected

    Can.Accessor field ->
      do  extVar <- mkFlexVar
          fieldVar <- mkFlexVar
          let extType = VarN extVar
          let fieldType = VarN fieldVar
          let recordType = RecordN (Map.singleton field fieldType) extType
          return $ exists [ fieldVar, extVar ] $
            CEqual region (Accessor field) (FunN recordType fieldType) expected

    Can.Access expr (A.At accessRegion field) ->
      do  extVar <- mkFlexVar
          fieldVar <- mkFlexVar
          let extType = VarN extVar
          let fieldType = VarN fieldVar
          let recordType = RecordN (Map.singleton field fieldType) extType

          let context = RecordAccess (A.toRegion expr) (getAccessName expr) accessRegion field
          recordCon <- constrain env expr (FromContext region context recordType)

          return $ exists [ fieldVar, extVar ] $
            CAnd
              [ recordCon
              , CEqual region (Access field) fieldType expected
              ]

    Can.Update name expr fields ->
      constrainUpdate env region name expr fields expected

    Can.Record fields ->
      constrainRecord env region fields expected

    Can.Unit ->
      return $ CEqual region Unit UnitN expected

    Can.Pair a b ->
      constrainPair env region a b expected

    Can.Triple a b c ->
      constrainTriple env region a b c expected

    Can.Shader _src types ->
      constrainShader region types expected



-- CONSTRAIN LAMBDA


constrainLambda :: Env -> A.Region -> [Can.Pattern] -> Can.Expr -> Expected Type -> IO Constraint
constrainLambda env region args body expected =
  do  (Args vars tipe resultType (Pattern.State headers pvars revCons)) <-
        constrainArgs (_recorder env) args

      bodyCon <-
        constrain env body (NoExpectation resultType)

      return $ exists vars $
        CAnd
          [ CLet
              { _rigidVars = []
              , _flexVars = pvars
              , _header = headers
              , _headerCon = CAnd (reverse revCons)
              , _bodyCon = bodyCon
              }
          , CEqual region Lambda tipe expected
          ]



-- CONSTRAIN CALL


constrainCall :: Env -> A.Region -> Can.Expr -> [Can.Expr] -> Expected Type -> IO Constraint
constrainCall env region func@(A.At funcRegion _) args expected =
  do  let maybeName = getName func

      funcVar <- mkFlexVar
      resultVar <- mkFlexVar
      let funcType = VarN funcVar
      let resultType = VarN resultVar

      funcCon <- constrain env func (NoExpectation funcType)

      (argVars, argTypes, argCons) <-
        unzip3 <$> Index.indexedTraverse (constrainArg env region maybeName) args

      let arityType = foldr FunN resultType argTypes
      let category = CallResult maybeName

      return $ exists (funcVar:resultVar:argVars) $
        CAnd
          [ funcCon
          , CEqual funcRegion category funcType (FromContext region (CallArity maybeName (length args)) arityType)
          , CAnd argCons
          , CEqual region category resultType expected
          ]


constrainArg :: Env -> A.Region -> MaybeName -> Index.ZeroBased -> Can.Expr -> IO (Variable, Type, Constraint)
constrainArg env region maybeName index arg =
  do  argVar <- mkFlexVar
      let argType = VarN argVar
      argCon <- constrain env arg (FromContext region (CallArg maybeName index) argType)
      return (argVar, argType, argCon)


getName :: Can.Expr -> MaybeName
getName (A.At _ expr) =
  case expr of
    Can.VarLocal name        -> FuncName name
    Can.VarTopLevel _ name   -> FuncName name
    Can.VarForeign _ name _  -> FuncName name
    Can.VarCtor _ _ name _ _ -> CtorName name
    Can.VarOperator op _ _ _ -> OpName op
    Can.VarKernel _ name     -> FuncName name
    _                        -> NoName


getAccessName :: Can.Expr -> Maybe N.Name
getAccessName (A.At _ expr) =
  case expr of
    Can.VarLocal name       -> Just name
    Can.VarTopLevel _ name  -> Just name
    Can.VarForeign _ name _ -> Just name
    _                       -> Nothing



-- CONSTRAIN BINOP


constrainBinop :: Env -> A.Region -> Op.Name -> Can.Annotation -> Can.Expr -> Can.Expr -> Expected Type -> IO Constraint
constrainBinop env region op annotation leftExpr rightExpr expected =
  do  leftVar <- mkFlexVar
      rightVar <- mkFlexVar
      answerVar <- mkFlexVar
      let leftType = VarN leftVar
      let rightType = VarN rightVar
      let answerType = VarN answerVar
      let binopType = leftType ==> rightType ==> answerType

      let opCon = COperator region op annotation (NoExpectation binopType)

      leftCon <- constrain env leftExpr (FromContext region (OpLeft op) leftType)
      rightCon <- constrain env rightExpr (FromContext region (OpRight op) rightType)

      return $ exists [ leftVar, rightVar, answerVar ] $
        CAnd
          [ opCon
          , leftCon
          , rightCon
          , CEqual region (CallResult (OpName op)) answerType expected
          ]



-- CONSTRAIN LISTS


constrainList :: Env -> A.Region -> [Can.Expr] -> Expected Type -> IO Constraint
constrainList env region entries expected =
  do  entryVar <- mkFlexVar
      let entryType = VarN entryVar
      let listType = AppN ModuleName.list T.list [entryType]

      entryCons <-
        Index.indexedTraverse (constrainListEntry env region entryType) entries

      return $ exists [entryVar] $
        CAnd
          [ CAnd entryCons
          , CEqual region List listType expected
          ]


constrainListEntry :: Env -> A.Region -> Type -> Index.ZeroBased -> Can.Expr -> IO Constraint
constrainListEntry env region tipe index expr =
  constrain env expr (FromContext region (ListEntry index) tipe)



-- CONSTRAIN IF EXPRESSIONS


constrainIf :: Env -> A.Region -> [(Can.Expr, Can.Expr)] -> Can.Expr -> Expected Type -> IO Constraint
constrainIf env region branches final expected =
  do  let boolExpect = FromContext region IfCondition Type.bool
      let (conditions, exprs) = foldr (\(c,e) (cs,es) -> (c:cs,e:es)) ([],[final]) branches

      condCons <-
        traverse (\c -> constrain env c boolExpect) conditions

      case expected of
        FromAnnotation name arity _ tipe ->
          do  branchCons <- Index.indexedForA exprs $ \index expr ->
                constrain env expr (FromAnnotation name arity (TypedIfBranch index) tipe)
              return $
                CAnd
                  [ CAnd condCons
                  , CAnd branchCons
                  ]

        _ ->
          do  branchVar <- mkFlexVar
              let branchType = VarN branchVar

              branchCons <- Index.indexedForA exprs $ \index expr ->
                constrain env expr (FromContext region (IfBranch index) branchType)

              return $ exists [branchVar] $
                CAnd
                  [ CAnd condCons
                  , CAnd branchCons
                  , CEqual region If branchType expected
                  ]



-- CONSTRAIN CASE EXPRESSIONS


constrainCase :: Env -> A.Region -> Can.Expr -> [Can.CaseBranch] -> Expected Type -> IO Constraint
constrainCase env region expr branches expected =
  do  ptrnVar <- mkFlexVar
      let ptrnType = VarN ptrnVar
      exprCon <- constrain env expr (NoExpectation ptrnType)

      case expected of
        FromAnnotation name arity _ tipe ->
          do  branchCons <- Index.indexedForA branches $ \index branch ->
                constrainCaseBranch env branch
                  (PFromContext region (PCaseMatch index) ptrnType)
                  (FromAnnotation name arity (TypedCaseBranch index) tipe)

              return $ exists [ptrnVar] $ CAnd (exprCon:branchCons)

        _ ->
          do  branchVar <- mkFlexVar
              let branchType = VarN branchVar

              branchCons <- Index.indexedForA branches $ \index branch ->
                constrainCaseBranch env branch
                  (PFromContext region (PCaseMatch index) ptrnType)
                  (FromContext region (CaseBranch index) branchType)

              return $ exists [ptrnVar,branchVar] $
                CAnd
                  [ exprCon
                  , CAnd branchCons
                  , CEqual region Case branchType expected
                  ]


constrainCaseBranch :: Env -> Can.CaseBranch -> PExpected Type -> Expected Type -> IO Constraint
constrainCaseBranch env (Can.CaseBranch pattern expr) pExpect bExpect =
  do  (Pattern.State headers pvars revCons) <-
        Pattern.add (_recorder env) pattern pExpect Pattern.emptyState

      CLet [] pvars headers (CAnd (reverse revCons))
        <$> constrain env expr bExpect



-- CONSTRAIN RECORD


constrainRecord :: Env -> A.Region -> Map.Map N.Name Can.Expr -> Expected Type -> IO Constraint
constrainRecord env region fields expected =
  do  dict <- traverse (constrainField env) fields

      let getType (_, t, _) = t
      let recordType = RecordN (Map.map getType dict) EmptyRecordN
      let recordCon = CEqual region Record recordType expected

      let vars = Map.foldr (\(v,_,_) vs -> v:vs) [] dict
      let cons = Map.foldr (\(_,_,c) cs -> c:cs) [recordCon] dict

      return $ exists vars (CAnd cons)


constrainField :: Env -> Can.Expr -> IO (Variable, Type, Constraint)
constrainField env expr =
  do  var <- mkFlexVar
      let tipe = VarN var
      con <- constrain env expr (NoExpectation tipe)
      return (var, tipe, con)



-- CONSTRAIN RECORD UPDATE


constrainUpdate :: Env -> A.Region -> N.Name -> Can.Expr -> Map.Map N.Name Can.FieldUpdate -> Expected Type -> IO Constraint
constrainUpdate env region name expr fields expected =
  do  extVar <- mkFlexVar
      fieldDict <- Map.traverseWithKey (constrainUpdateField env region) fields

      recordVar <- mkFlexVar
      let recordType = VarN recordVar
      let fieldsType = RecordN (Map.map (\(_,t,_) -> t) fieldDict) (VarN extVar)

      -- NOTE: fieldsType is separate so that Error propagates better
      let fieldsCon = CEqual region Record recordType (NoExpectation fieldsType)
      let recordCon = CEqual region Record recordType expected

      let vars = Map.foldr (\(v,_,_) vs -> v:vs) [recordVar,extVar] fieldDict
      let cons = Map.foldr (\(_,_,c) cs -> c:cs) [recordCon] fieldDict

      con <- constrain env expr (FromContext region (RecordUpdateKeys name fields) recordType)

      return $ exists vars $ CAnd (fieldsCon:con:cons)


constrainUpdateField :: Env -> A.Region -> N.Name -> Can.FieldUpdate -> IO (Variable, Type, Constraint)
constrainUpdateField env region field (Can.FieldUpdate _ expr) =
  do  var <- mkFlexVar
      let tipe = VarN var
      con <- constrain env expr (FromContext region (RecordUpdateValue field) tipe)
      return (var, tipe, con)



-- CONSTRAIN TUPLE


constrainPair :: Env -> A.Region -> Can.Expr -> Can.Expr -> Expected Type -> IO Constraint
constrainPair env region a b expected =
  do  aVar <- mkFlexVar
      bVar <- mkFlexVar
      let aType = VarN aVar
      let bType = VarN bVar

      aCon <- constrain env a (NoExpectation aType)
      bCon <- constrain env b (NoExpectation bType)

      let tupleType = PairN aType bType
      let tupleCon = CEqual region Tuple tupleType expected

      return $ exists [ aVar, bVar ] $ CAnd [ aCon, bCon, tupleCon ]


constrainTriple :: Env -> A.Region -> Can.Expr -> Can.Expr -> Can.Expr -> Expected Type -> IO Constraint
constrainTriple env region a b c expected =
  do  aVar <- mkFlexVar
      bVar <- mkFlexVar
      cVar <- mkFlexVar
      let aType = VarN aVar
      let bType = VarN bVar
      let cType = VarN cVar

      aCon <- constrain env a (NoExpectation aType)
      bCon <- constrain env b (NoExpectation bType)
      cCon <- constrain env c (NoExpectation cType)

      let tupleType = TripleN aType bType cType
      let tupleCon = CEqual region Tuple tupleType expected

      return $ exists [ aVar, bVar, cVar ] $ CAnd [ aCon, bCon, cCon, tupleCon ]



-- CONSTRAIN SHADER


constrainShader :: A.Region -> Shader.Types -> Expected Type -> IO Constraint
constrainShader region (Shader.Types attributes uniforms varyings) expected =
  do  attrVar <- mkFlexVar
      unifVar <- mkFlexVar
      let attrType = VarN attrVar
      let unifType = VarN unifVar

      let shaderType =
            AppN ModuleName.webgl T.shader
              [ toShaderRecord attributes attrType
              , toShaderRecord uniforms unifType
              , toShaderRecord varyings EmptyRecordN
              ]

      return $ exists [ attrVar, unifVar ] $
        CEqual region Shader shaderType expected


toShaderRecord :: Map.Map N.Name Shader.Type -> Type -> Type
toShaderRecord types baseRecType =
  if Map.null types then
    baseRecType
  else
    RecordN (Map.map glToType types) baseRecType


glToType :: Shader.Type -> Type
glToType glType =
  case glType of
    Shader.V2 -> Type.vec2
    Shader.V3 -> Type.vec3
    Shader.V4 -> Type.vec4
    Shader.M4 -> Type.mat4
    Shader.Int -> Type.int
    Shader.Float -> Type.float
    Shader.Texture -> Type.texture



-- CONSTRAIN DESTRUCTURES


constrainDestruct :: Env -> A.Region -> Can.Pattern -> Can.Expr -> Constraint -> IO Constraint
constrainDestruct env region pattern expr bodyCon =
  do  patternVar <- mkFlexVar
      let patternType = VarN patternVar

      (Pattern.State headers pvars revCons) <-
        Pattern.add (_recorder env) pattern (PNoExpectation patternType) Pattern.emptyState

      exprCon <-
        constrain env expr (FromContext region Destructure patternType)

      return $ CLet [] (patternVar:pvars) headers (CAnd (reverse (exprCon:revCons))) bodyCon



-- CONSTRAIN DEF


-- In typed mode a definition gets a variable for its type scheme. The header of
-- the definition then is that variable, made equal to the real header type.
-- The variable is generalized together with the rest of the definition, so
-- after solving it is the scheme that every use copies.
defHeader :: Env -> A.Region -> N.Name -> Type -> IO ([Variable], Type, [Constraint])
defHeader env region name tipe =
  case _recorder env of
    Nothing ->
      return ([], tipe, [])

    Just recorder ->
      do  var <- mkFlexVar
          Recorder.recordDef recorder region name var
          return ([var], VarN var, [CEqual region Unit (VarN var) (NoExpectation tipe)])


constrainDef :: Env -> Can.Def -> Constraint -> IO Constraint
constrainDef env def bodyCon =
  case def of
    Can.Def (A.At region name) args expr ->
      do  (Args vars tipe resultType (Pattern.State headers pvars revCons)) <-
            constrainArgs (_recorder env) args

          exprCon <-
            constrain env expr (NoExpectation resultType)

          (schemeVars, headerType, schemeCons) <-
            defHeader env region name tipe

          return $
            CLet
              { _rigidVars = []
              , _flexVars = schemeVars ++ vars
              , _header = Map.singleton name (A.At region headerType)
              , _headerCon =
                  CAnd $ schemeCons ++
                    [ CLet
                        { _rigidVars = []
                        , _flexVars = pvars
                        , _header = headers
                        , _headerCon = CAnd (reverse revCons)
                        , _bodyCon = exprCon
                        }
                    ]
              , _bodyCon = bodyCon
              }

    Can.TypedDef (A.At region name) freeVars typedArgs expr srcResultType ->
      do  let newNames = Map.difference freeVars (_rtv env)
          newRigids <- Map.traverseWithKey (\n _ -> nameToRigid n) newNames
          let newRtv = Map.union (_rtv env) (Map.map VarN newRigids)
          let newEnv = env { _rtv = newRtv }

          (TypedArgs tipe resultType (Pattern.State headers pvars revCons)) <-
            constrainTypedArgs (_recorder env) newRtv name typedArgs srcResultType

          let expected = FromAnnotation name (length typedArgs) TypedBody resultType
          exprCon <-
            constrain newEnv expr expected

          (schemeVars, headerType, schemeCons) <-
            defHeader env region name tipe

          return $
            CLet
              { _rigidVars = Map.elems newRigids
              , _flexVars = schemeVars
              , _header = Map.singleton name (A.At region headerType)
              , _headerCon =
                  CAnd $ schemeCons ++
                    [ CLet
                        { _rigidVars = []
                        , _flexVars = pvars
                        , _header = headers
                        , _headerCon = CAnd (reverse revCons)
                        , _bodyCon = exprCon
                        }
                    ]
              , _bodyCon = bodyCon
              }



-- CONSTRAIN RECURSIVE DEFS


data Info =
  Info
    { _vars :: [Variable]
    , _schemeVars :: [Variable]
    , _schemeCons :: [Constraint]
    , _cons :: [Constraint]
    , _headers :: Map.Map N.Name (A.Located Type)
    }


{-# NOINLINE emptyInfo #-}
emptyInfo :: Info
emptyInfo =
  Info [] [] [] [] Map.empty


constrainRecursiveDefs :: Env -> [Can.Def] -> Constraint -> IO Constraint
constrainRecursiveDefs env defs bodyCon =
  recDefsHelp env defs bodyCon emptyInfo emptyInfo


recDefsHelp :: Env -> [Can.Def] -> Constraint -> Info -> Info -> IO Constraint
recDefsHelp env defs bodyCon rigidInfo flexInfo =
  case defs of
    [] ->
      do  let (Info rigidVars rigidSchemeVars rigidSchemeCons rigidCons rigidHeaders) = rigidInfo
          let (Info flexVars  flexSchemeVars  _               flexCons  flexHeaders ) = flexInfo
          return $
            CLet rigidVars rigidSchemeVars rigidHeaders (CAnd rigidSchemeCons) $
              CLet [] (flexSchemeVars ++ flexVars) flexHeaders (CLet [] [] flexHeaders CTrue (CAnd flexCons)) $
                CAnd [ CAnd rigidCons, bodyCon ]

    def : otherDefs ->
      case def of
        Can.Def (A.At region name) args expr ->
          do  let (Info flexVars flexSchemeVars _ flexCons flexHeaders) = flexInfo

              -- Each definition starts from an empty pattern state, and the variables of all
              -- definitions of the group are generalized together by the outer let (as in 0.19.4).
              -- Passing the previous definition's variables in made the let of this definition
              -- generalize them before any body was solved (elm/compiler#2274).
              (Args newFlexVars tipe resultType (Pattern.State headers pvars revCons)) <-
                argsHelp (_recorder env) args Pattern.emptyState

              exprCon <-
                constrain env expr (NoExpectation resultType)

              (schemeVars, headerType, schemeCons) <-
                defHeader env region name tipe

              let defCon =
                    CLet
                      { _rigidVars = []
                      , _flexVars = pvars
                      , _header = headers
                      , _headerCon = CAnd (reverse revCons)
                      , _bodyCon = exprCon
                      }

              recDefsHelp env otherDefs bodyCon rigidInfo $
                Info
                  { _vars = newFlexVars ++ flexVars
                  , _schemeVars = schemeVars ++ flexSchemeVars
                  , _schemeCons = []
                  , _cons = schemeCons ++ (defCon : flexCons)
                  , _headers = Map.insert name (A.At region headerType) flexHeaders
                  }

        Can.TypedDef (A.At region name) freeVars typedArgs expr srcResultType ->
          do  let newNames = Map.difference freeVars (_rtv env)
              newRigids <- Map.traverseWithKey (\n _ -> nameToRigid n) newNames
              let newRtv = Map.union (_rtv env) (Map.map VarN newRigids)
              let newEnv = env { _rtv = newRtv }

              (TypedArgs tipe resultType (Pattern.State headers pvars revCons)) <-
                constrainTypedArgs (_recorder env) newRtv name typedArgs srcResultType

              exprCon <-
                constrain newEnv expr $
                  FromAnnotation name (length typedArgs) TypedBody resultType

              (schemeVars, headerType, schemeCons) <-
                defHeader env region name tipe

              let defCon =
                    CLet
                      { _rigidVars = []
                      , _flexVars = pvars
                      , _header = headers
                      , _headerCon = CAnd (reverse revCons)
                      , _bodyCon = exprCon
                      }

              let (Info rigidVars rigidSchemeVars rigidSchemeCons rigidCons rigidHeaders) = rigidInfo
              recDefsHelp env otherDefs bodyCon
                ( Info
                    { _vars = Map.foldr (:) rigidVars newRigids
                    , _schemeVars = schemeVars ++ rigidSchemeVars
                    , _schemeCons = schemeCons ++ rigidSchemeCons
                    , _cons = CLet (Map.elems newRigids) [] (nameOnlyHeader region name) defCon CTrue : rigidCons
                    , _headers = Map.insert name (A.At region headerType) rigidHeaders
                    }
                )
                flexInfo



-- The solver reports a rigid variable that escapes its let (elm/compiler#1639) using the
-- names in the header of the CLet. The CLet built for an annotated definition of a recursive
-- group has no header of its own (its names are bound by the enclosing let), so this
-- gives it one entry that carries only the name and region for that report. The type is
-- the closed type Int: it has no variables, so it cannot change inference, and the name is
-- only visible to the (trivial) body constraint CTrue.
nameOnlyHeader :: A.Region -> N.Name -> Map.Map N.Name (A.Located Type)
nameOnlyHeader region name =
  Map.singleton name (A.At region Type.int)


-- CONSTRAIN ARGS


data Args =
  Args
    { _a_vars :: [Variable]
    , _a_type :: Type
    , _a_result :: Type
    , _a_state :: Pattern.State
    }


constrainArgs :: Maybe Recorder.Recorder -> [Can.Pattern] -> IO Args
constrainArgs maybeRec args =
  argsHelp maybeRec args Pattern.emptyState


argsHelp :: Maybe Recorder.Recorder -> [Can.Pattern] -> Pattern.State -> IO Args
argsHelp maybeRec args state =
  case args of
    [] ->
      do  resultVar <- mkFlexVar
          let resultType = VarN resultVar
          return $ Args [resultVar] resultType resultType state

    pattern : otherArgs ->
      do  argVar <- mkFlexVar
          let argType = VarN argVar

          (Args vars tipe result newState) <-
            argsHelp maybeRec otherArgs =<<
              Pattern.add maybeRec pattern (PNoExpectation argType) state

          return (Args (argVar:vars) (FunN argType tipe) result newState)



-- CONSTRAIN TYPED ARGS


-- Ficcus (ATTACH A2): the hidden parameters of a constrained definition are not counted in "the 2nd argument"
isHidden :: Can.Pattern -> Bool
isHidden (A.At _ pattern) =
  case pattern of
    Can.PAlias (A.At _ (Can.PVar marker)) _ -> Maybe.isJust (Constraints.splitMarker marker)
    _ -> False


data TypedArgs =
  TypedArgs
    { _t_type :: Type
    , _t_result :: Type
    , _t_state :: Pattern.State
    }


constrainTypedArgs :: Maybe Recorder.Recorder -> Map.Map T.Var Type -> N.Name -> [(Can.Pattern, Can.Type)] -> Can.Type -> IO TypedArgs
constrainTypedArgs maybeRec rtv name args srcResultType =
  typedArgsHelp maybeRec rtv name Index.first args srcResultType Pattern.emptyState


typedArgsHelp :: Maybe Recorder.Recorder -> Map.Map T.Var Type -> N.Name -> Index.ZeroBased -> [(Can.Pattern, Can.Type)] -> Can.Type -> Pattern.State -> IO TypedArgs
typedArgsHelp maybeRec rtv name index args srcResultType state =
  case args of
    [] ->
      do  resultType <- Instantiate.fromSrcType rtv srcResultType
          return $ TypedArgs resultType resultType state

    (pattern@(A.At region _), srcType) : otherArgs ->
      do  argType <- Instantiate.fromSrcType rtv srcType
          let expected = PFromContext region (PTypedArg name index) argType

          (TypedArgs tipe resultType newState) <-
            typedArgsHelp maybeRec rtv name (if isHidden pattern then index else Index.next index) otherArgs srcResultType =<<
              Pattern.add maybeRec pattern expected state

          return (TypedArgs (FunN argType tipe) resultType newState)
