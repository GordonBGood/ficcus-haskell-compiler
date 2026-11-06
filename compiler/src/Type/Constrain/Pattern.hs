module Type.Constrain.Pattern
  ( State(..)
  , emptyState
  , add
  )
  where


import Control.Arrow (second)
import Control.Monad (foldM)
import qualified Data.Map.Strict as Map

import qualified AST.Canonical as Can
import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeName as T (Name, list)
import qualified AST.Prim.TypeVar as T
import qualified Data.Index as Index
import qualified Elm.ModuleName as ModuleName
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Type as E
import qualified Type.Instantiate as Instantiate
import qualified Type.Recorder as Recorder
import Type.Type as T



-- ACTUALLY ADD CONSTRAINTS


-- The constraints are stored in reverse order so that adding a new
-- constraint is O(1) and we can reverse it at some later time.
--
data State =
  State
    { _headers :: Header
    , _vars :: [Variable]
    , _revCons :: [Constraint]
    }


type Header = Map.Map N.Name (A.Located Type)


-- In typed mode (Just recorder) every pattern node also gets a type variable of
-- its own: a flex variable equal to the type the pattern is expected to have.
add :: Maybe Recorder.Recorder -> Can.Pattern -> E.PExpected Type -> State -> IO State
add maybeRec pat@(A.At region pattern) expectation state =
  do  newState <- addHelp maybeRec pat expectation state
      case maybeRec of
        Nothing ->
          return newState

        Just recorder ->
          do  var <- mkFlexVar
              Recorder.recordPat recorder region pattern var
              let (State headers vars revCons) = newState
              let eqCon = CEqual region E.Unit (VarN var) (E.NoExpectation (getType expectation))
              return $ State headers (var:vars) (eqCon:revCons)


addHelp :: Maybe Recorder.Recorder -> Can.Pattern -> E.PExpected Type -> State -> IO State
addHelp maybeRec (A.At region pattern) expectation state =
  case pattern of
    Can.PAnything ->
      return state

    Can.PVar name ->
      return $ addToHeaders region name expectation state

    Can.PAlias realPattern name ->
      add maybeRec realPattern expectation $
        addToHeaders region name expectation state

    Can.PUnit ->
      do  let (State headers vars revCons) = state
          let unitCon = CPattern region E.PUnit UnitN expectation
          return $ State headers vars (unitCon:revCons)

    Can.PPair a b ->
      addPair maybeRec region a b expectation state

    Can.PTriple a b c ->
      addTriple maybeRec region a b c expectation state

    Can.PCtor home typeName (Can.Union typeVars _ _ _) ctorName _ args ->
      addCtor maybeRec region home typeName typeVars ctorName args expectation state

    Can.PList patterns ->
      do  entryVar <- mkFlexVar
          let entryType = VarN entryVar
          let listType = AppN ModuleName.list T.list [entryType]

          (State headers vars revCons) <-
            foldM (addEntry maybeRec region entryType) state (Index.indexedMap (,) patterns)

          let listCon = CPattern region E.PList listType expectation
          return $ State headers (entryVar:vars) (listCon:revCons)

    Can.PCons headPattern tailPattern ->
      do  entryVar <- mkFlexVar
          let entryType = VarN entryVar
          let listType = AppN ModuleName.list T.list [entryType]

          let headExpectation = E.PNoExpectation entryType
          let tailExpectation = E.PFromContext region E.PTail listType

          (State headers vars revCons) <-
            add maybeRec headPattern headExpectation =<<
              add maybeRec tailPattern tailExpectation state

          let listCon = CPattern region E.PList listType expectation
          return $ State headers (entryVar:vars) (listCon : revCons)

    Can.PRecord fields ->
      do  extVar <- mkFlexVar
          let extType = VarN extVar

          fieldVars <- traverse (\field -> (,) field <$> mkFlexVar) fields
          let fieldTypes = Map.fromList (map (fmap VarN) fieldVars)
          let recordType = RecordN fieldTypes extType

          let (State headers vars revCons) = state
          let recordCon = CPattern region E.PRecord recordType expectation
          return $
            State
              { _headers = Map.union headers (Map.map (A.At region) fieldTypes)
              , _vars = map snd fieldVars ++ extVar : vars
              , _revCons = recordCon : revCons
              }

    Can.PInt _ ->
      do  let (State headers vars revCons) = state
          let intCon = CPattern region E.PInt T.int expectation
          return $ State headers vars (intCon:revCons)

    Can.PStr _ ->
      do  let (State headers vars revCons) = state
          let strCon = CPattern region E.PStr T.string expectation
          return $ State headers vars (strCon:revCons)

    Can.PChr _ ->
      do  let (State headers vars revCons) = state
          let chrCon = CPattern region E.PChr T.char expectation
          return $ State headers vars (chrCon:revCons)

    Can.PBool _ _ ->
      do  let (State headers vars revCons) = state
          let boolCon = CPattern region E.PBool T.bool expectation
          return $ State headers vars (boolCon:revCons)



-- STATE HELPERS


{-# NOINLINE emptyState #-}
emptyState :: State
emptyState =
  State Map.empty [] []


addToHeaders :: A.Region -> N.Name -> E.PExpected Type -> State -> State
addToHeaders region name expectation (State headers vars revCons) =
  let
    tipe = getType expectation
    newHeaders = Map.insert name (A.At region tipe) headers
  in
  State newHeaders vars revCons


getType :: E.PExpected Type -> Type
getType expectation =
  case expectation of
    E.PNoExpectation tipe -> tipe
    E.PFromContext _ _ tipe -> tipe



-- CONSTRAIN LIST


addEntry :: Maybe Recorder.Recorder -> A.Region -> Type -> State -> (Index.ZeroBased, Can.Pattern) -> IO State
addEntry maybeRec listRegion tipe state (index, pattern) =
  let
    expectation =
      E.PFromContext listRegion (E.PListEntry index) tipe
  in
  add maybeRec pattern expectation state



-- CONSTRAIN TUPLE


addPair :: Maybe Recorder.Recorder -> A.Region -> Can.Pattern -> Can.Pattern -> E.PExpected Type -> State -> IO State
addPair maybeRec region a b expectation state =
  do  aVar <- mkFlexVar
      bVar <- mkFlexVar
      let aType = VarN aVar
      let bType = VarN bVar

      (State headers vars revCons) <-
        simpleAdd maybeRec b bType =<<
        simpleAdd maybeRec a aType state

      let tupleCon = CPattern region E.PTuple (PairN aType bType) expectation

      return $ State headers (aVar:bVar:vars) (tupleCon:revCons)


addTriple :: Maybe Recorder.Recorder -> A.Region -> Can.Pattern -> Can.Pattern -> Can.Pattern -> E.PExpected Type -> State -> IO State
addTriple maybeRec region a b c expectation state =
  do  aVar <- mkFlexVar
      bVar <- mkFlexVar
      cVar <- mkFlexVar
      let aType = VarN aVar
      let bType = VarN bVar
      let cType = VarN cVar

      (State headers vars revCons) <-
        simpleAdd maybeRec c cType =<<
        simpleAdd maybeRec b bType =<<
        simpleAdd maybeRec a aType state

      let tupleCon = CPattern region E.PTuple (TripleN aType bType cType) expectation

      return $ State headers (aVar:bVar:cVar:vars) (tupleCon:revCons)


simpleAdd :: Maybe Recorder.Recorder -> Can.Pattern -> Type -> State -> IO State
simpleAdd maybeRec pattern patternType state =
  add maybeRec pattern (E.PNoExpectation patternType) state



-- CONSTRAIN CONSTRUCTORS


addCtor :: Maybe Recorder.Recorder -> A.Region -> ModuleName.Canonical -> T.Name -> [T.Var] -> N.Name -> [Can.PatternCtorArg] -> E.PExpected Type -> State -> IO State
addCtor maybeRec region home typeName typeVarNames ctorName args expectation state =
  do  varPairs <- traverse (\var -> (,) var <$> nameToFlex var) typeVarNames
      let typePairs = map (second VarN) varPairs
      let freeVarDict = Map.fromList typePairs

      (State headers vars revCons) <-
        foldM (addCtorArg maybeRec region ctorName freeVarDict) state args

      let ctorType = AppN home typeName (map snd typePairs)
      let ctorCon = CPattern region (E.PCtor ctorName) ctorType expectation

      return $
        State
          { _headers = headers
          , _vars = map snd varPairs ++ vars
          , _revCons = ctorCon : revCons
          }


addCtorArg :: Maybe Recorder.Recorder -> A.Region -> N.Name -> Map.Map T.Var Type -> State -> Can.PatternCtorArg -> IO State
addCtorArg maybeRec region ctorName freeVarDict state (Can.PatternCtorArg index srcType pattern) =
  do  tipe <- Instantiate.fromSrcType freeVarDict srcType
      let expectation = E.PFromContext region (E.PCtorArg ctorName index) tipe
      add maybeRec pattern expectation state
