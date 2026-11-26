{-# LANGUAGE OverloadedStrings, TemplateHaskell, PatternGuards #-}
module Type.Solve
  ( run
  , runWith
  )
  where


import Control.Monad
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import qualified Data.Map.Utils as Map
import qualified Data.NonEmptyList as NE
import qualified Data.Vector as Vector
import qualified Data.Vector.Mutable as MVector

import qualified Crash

import qualified AST.Canonical as Can
import qualified AST.Constraints as Constraints
import qualified AST.Prim.Name as N
import qualified AST.Prim.Operator as Op
import qualified String as S
import qualified AST.Prim.TypeVar as T
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Type as Error
import qualified Type.Error as ET
import qualified Elm.ModuleName as ModuleName
import qualified Type.Members as Members
import qualified Type.Occurs as Occurs
import qualified Type.Requirements as Requirements
import Type.Type as Type
import qualified Type.Unify as Unify
import qualified Type.UnionFind as UF



-- RUN SOLVER


run :: Constraint -> IO (Either (NE.List Error.Error) (Map.Map N.Name Can.Annotation))
run =
  runWith Members.emptyTable Map.empty


-- Ficcus (ATTACH A2): with the table of the members that the module can see (Type.Members)
-- (A5a: and what each definition is, for the monomorphism restriction, Type.Requirements)
runWith :: Members.Table -> Requirements.Kinds -> Constraint -> IO (Either (NE.List Error.Error) (Map.Map N.Name Can.Annotation))
runWith table kinds constraint =
  do  pools <- MVector.replicate 8 []

      flag <- newIORef False
      (State env _ errors0 _ pending _ _) <-
        solve Map.empty outermostRank pools (emptyState { _table = table, _flag = Just flag, _kinds = kinds }) constraint

      errors <-
        case pending of
          [] -> return errors0
          _  -> (++ errors0) <$> Members.leftovers pending

      case Members.merge errors of
        [] ->
          do  annotations <- traverse Type.toAnnotation env
              -- Ficcus (ATTACH A3): did an operator or a bundle meet a custom type? (the JavaScript output refuses such a program)
              used <- readIORef flag
              return $ Right $
                if used then Map.insert Constraints.customOperators (Can.Forall Map.empty Can.TUnit) annotations else annotations

        e:es ->
          return $ Left (NE.List e es)



{-# NOINLINE emptyState #-}
emptyState :: State
emptyState =
  State Map.empty (nextMark noMark) [] Members.emptyTable [] Nothing Map.empty



-- SOLVER


type Env =
  Map.Map N.Name Variable


type Pools =
  MVector.IOVector [Variable]


data State =
  State
    { _env :: Env
    , _mark :: Mark
    , _errors :: [Error.Error]
    , _table :: Members.Table             -- Ficcus (ATTACH A2): the members the module can see
    , _pending :: [Members.Obligation]    -- the member obligations not yet discharged
    , _flag :: Maybe (IORef Bool)         -- Ficcus (ATTACH A3): set when a custom type took the place of a `number`, `comparable`, ... variable
    , _kinds :: Requirements.Kinds        -- Ficcus (A5a): functions, values and annotated definitions by the region of their name
    }


solve :: Env -> Int -> Pools -> State -> Constraint -> IO State
solve env rank pools state constraint =
  case constraint of
    CTrue ->
      return state

    CSaveTheEnvironment ->
      return (state { _env = env })

    -- Ficcus (A3b): a Float literal in a module that sees a type with `fromFloat` (Members.floatLiterals)
    CEqual region Error.Float _ expectation | Just (member, Can.Forall vars shape, defaultType) <- Members.floatLiterals (_table state) ->
      do  pair <- srcTypeToVariable rank pools vars shape
          (Descriptor content _ _ _) <- UF.get pair
          (actual, state1) <-
            case content of
              Structure (Pair1 subject fn) ->
                return (subject, state { _pending = Members.relaxedObligation region Members.floatLiteralName member subject fn defaultType : _pending state })
              _ ->
                return (pair, state)
          expected <- expectedToVariable rank pools expectation
          answer <- Unify.unifyWith (Members.policyOf (_flag state1) (_table state1)) actual expected
          case answer of
            Unify.Ok vars' ->
              do  introduce rank pools vars'
                  return state1

            Unify.Runaway isCycle ->
              return $ addError state1 (Error.Runaway region isCycle)

            Unify.Err vars' actualType expectedType ->
              do  introduce rank pools vars'
                  return $ addError state1 $ noted state1 actualType expectedType $
                    Error.BadExpr region Error.Float actualType $
                      Error.typeReplace expectation expectedType

    CEqual region category tipe expectation ->
      do  actual <- typeToVariable rank pools tipe
          expected <- expectedToVariable rank pools expectation
          answer <- Unify.unifyWith (Members.policyOf (_flag state) (_table state)) actual expected
          case answer of
            Unify.Ok vars ->
              do  introduce rank pools vars
                  return state

            Unify.Runaway isCycle ->
              return $ addError state (Error.Runaway region isCycle)

            Unify.Err vars actualType expectedType ->
              do  introduce rank pools vars
                  return $ addError state $ noted state actualType expectedType $
                    Error.BadExpr region category actualType $
                      Error.typeReplace expectation expectedType

    CLocal region name expectation ->
      do  copy <- makeCopy rank pools $ $(Map.require 'solve) name env N.toChars
          -- Ficcus (A5a): a definition with inferred requirements is bound to its carrier (Type.Requirements.carrier);
          -- the copy gives the type of this use and its obligations, sharing their variables
          (actual, state1) <-
            do  (Descriptor content _ _ _) <- UF.get copy
                case content of
                  Structure (App1 _ wname _) | wname == Constraints.whereName ->
                    do  (real, obligations) <- Members.use region name copy
                        return (real, state { _pending = obligations ++ _pending state })
                  _ ->
                    return (copy, state)
          expected <- expectedToVariable rank pools expectation
          answer <- Unify.unifyWith (Members.policyOf (_flag state1) (_table state1)) actual expected
          case answer of
            Unify.Ok vars ->
              do  introduce rank pools vars
                  return state1

            Unify.Runaway isCycle ->
              return $ addError state1 (Error.Runaway region isCycle)

            Unify.Err vars actualType expectedType ->
              do  introduce rank pools vars
                  return $ addError state1 $ noted state1 actualType expectedType $
                    Error.BadExpr region (Error.Local name) actualType $
                      Error.typeReplace expectation expectedType

    CForeign region name home (Can.Forall freeVars srcType) expectation ->
      do  (actual0, state0) <- instantiateUse rank pools state region home name freeVars srcType
          -- Ficcus (ATTACH A2): a constrained scheme leaves an obligation for each required member
          (actual, state1) <-
            if Constraints.isWrapped srcType
              then
                do  (real, obligations) <- Members.use region name actual0
                    return (real, state0 { _pending = obligations ++ _pending state0 })
              else
                return (actual0, state0)
          expected <- expectedToVariable rank pools expectation
          answer <- Unify.unifyWith (Members.policyOf (_flag state) (_table state)) actual expected
          case answer of
            Unify.Ok vars ->
              do  introduce rank pools vars
                  return state1

            Unify.Runaway isCycle ->
              return $ addError state1 (Error.Runaway region isCycle)

            Unify.Err vars actualType expectedType ->
              do  introduce rank pools vars
                  return $ addError state1 $ noted state1 actualType expectedType $
                    Error.BadExpr region (Error.Foreign name) actualType $
                      Error.typeReplace expectation expectedType

    COperator region op home (Can.Forall freeVars srcType) expectation ->
      do  (actual, state0) <- instantiateUse rank pools state region home (N.fromString (S.fromChars (Op.toChars op))) freeVars srcType
          expected <- expectedToVariable rank pools expectation
          answer <- Unify.unifyWith (Members.policyOf (_flag state0) (_table state0)) actual expected
          case answer of
            Unify.Ok vars ->
              do  introduce rank pools vars
                  return state0

            Unify.Runaway isCycle ->
              return $ addError state0 (Error.Runaway region isCycle)

            Unify.Err vars actualType expectedType ->
              do  introduce rank pools vars
                  return $ addError state0 $ noted state0 actualType expectedType $
                    Error.BadExpr region (Error.Operator op) actualType $
                      Error.typeReplace expectation expectedType

    CPattern region category tipe expectation ->
      do  actual <- typeToVariable rank pools tipe
          expected <- patternExpectationToVariable rank pools expectation
          answer <- Unify.unifyWith (Members.policyOf (_flag state) (_table state)) actual expected
          case answer of
            Unify.Ok vars ->
              do  introduce rank pools vars
                  return state

            Unify.Runaway isCycle ->
              return $ addError state (Error.Runaway region isCycle)

            Unify.Err vars actualType expectedType ->
              do  introduce rank pools vars
                  return $ addError state $
                    Error.BadPattern region category actualType
                      (Error.ptypeReplace expectation expectedType)

    CAnd constraints ->
      foldM (solve env rank pools) state constraints

    -- (A3c, F8) a definition at the outermost rank (a top level one) always takes the general case below, so that it has a
    -- rank of its own: Type.Requirements tells a top level definition from a let by its rank (A5a; it was Members.defaulting
    -- and Members.hold), and a definition without variables (`poly : ( Money, Money )`) took these two cases, so its own
    -- relaxed uses were never defaulted and its let definitions counted as top level ones.  The typed mode
    -- (Type.Constrain.Expression.defHeader) always gave it a variable, so the two output modes checked such a program differently
    CLet [] flexs header headerCon CTrue | not (topLevel rank header) ->
      do  introduce rank pools flexs
          solve env rank pools state headerCon

    CLet [] [] header headerCon subCon | not (topLevel rank header) ->
      do  state1 <- solve env rank pools state headerCon
          locals <- traverse (A.traverse (typeToVariable rank pools)) header
          let newEnv = Map.union env (Map.map A.toValue locals)
          state2 <- discharge newEnv rank pools =<< solve newEnv rank pools state1 subCon
          foldM occurs state2 $ Map.toList locals

    CLet rigids flexs header headerCon subCon ->
      do
          -- work in the next pool to localize header
          let nextRank = rank + 1
          let poolsLength = MVector.length pools
          nextPools <-
            if nextRank < poolsLength
              then return pools
              else MVector.grow pools poolsLength

          -- introduce variables
          let vars = rigids ++ flexs
          forM_ vars $ \var ->
            UF.modify var $ \(Descriptor content _ mark copy) ->
              Descriptor content nextRank mark copy
          MVector.write nextPools nextRank vars

          -- run solver in next pool
          locals <- traverse (A.traverse (typeToVariable nextRank nextPools)) header
          (State savedEnv mark0 errors table pending00 flag kinds) <-
            discharge env nextRank nextPools =<< solve env nextRank nextPools state headerCon

          -- (A5a) what the pending requirements become: held (determined from the context, or the monomorphism
          -- restriction in a let), part of the scheme (a function whose type determines them), or defaulted or
          -- reported (the top level); see Type.Requirements.  Never reached by an Elm program (nothing is pending).
          (pendingHeld, scheme, settleErrors, mark) <-
            case pending00 of
              [] -> return ([], [], [], mark0)
              _ ->
                do  -- the true ranks first: a variable made here may be part of an older one (Elm's generalize
                    -- finds that out by the same walk)
                    let m2 = nextMark mark0
                    let m3 = nextMark m2
                    adjustRanks mark0 m2 m3 nextRank nextPools
                    let tools =
                          Members.Tools
                            (\(Can.Forall freeVars srcType) -> srcTypeToVariable nextRank nextPools freeVars srcType)
                            (introduce nextRank nextPools)
                            (Members.policyOf flag table)
                            (maybe (return ()) (\ref -> writeIORef ref True) flag)
                    let kind = Requirements.kindOfHeader kinds header
                    (Requirements.Outcome kept sch errs) <- Requirements.settle tools table env kind rank nextRank locals pending00
                    return (kept, sch, errs, nextMark m3)

          -- (A5a) the carrier of each name whose type determines requirements of the scheme
          carriers <-
            case scheme of
              [] -> return Map.empty
              _ -> Map.mapMaybe id <$> traverse (\(A.At _ var) -> Requirements.carrier (register nextRank nextPools) var scheme) locals

          let youngMark = mark
          let visitMark = nextMark youngMark
          let finalMark = nextMark visitMark

          -- pop pool
          let grayMark = nextMark finalMark
          hiddenCycle <- generalize youngMark visitMark grayMark nextRank nextPools
          MVector.write nextPools nextRank []

          -- check that things went well: a rigid variable that was unified with
          -- a variable of an outer definition is no longer generic (elm/compiler#1639)
          escapes <- fmap concat (traverse (rigidEscape header) rigids)

          let newEnv = Map.union env (Map.union carriers (Map.map A.toValue locals))
          -- a cycle among the variables of this definition that its type does not show (Ficcus D10, 1491);
          -- only reported when nothing else went wrong before (after an error such cycles are a consequence)
          let cycles =
                case Map.toList header of
                  (name, A.At region _) : _ | hiddenCycle && null errors && null escapes -> [Error.HiddenCycle region name]
                  _ -> []
          -- (ATTACH A2) an obligation whose subject was generalized can never be discharged
          (pending, memberErrors) <-
            case pendingHeld of
              [] -> return ([], settleErrors)
              _  -> (\(kept, errs) -> (kept, errs ++ settleErrors)) <$> Members.sweep pendingHeld
          let tempState = State savedEnv grayMark (memberErrors ++ cycles ++ escapes ++ errors) table pending flag kinds
          newState <- discharge newEnv rank nextPools =<< solve newEnv rank nextPools tempState subCon

          foldM occurs newState (Map.toList locals)


-- (A3c) a definition at the outermost rank
topLevel :: Int -> Map.Map N.Name a -> Bool
topLevel rank header =
  rank == outermostRank && not (Map.null header)


-- Check that a rigid variable still has rank == noRank, meaning that it can be
-- generalized. If not, it was unified with something from an outer scope: report
-- that as a type error (it used to be a compiler crash).
rigidEscape :: Map.Map N.Name (A.Located Type) -> Variable -> IO [Error.Error]
rigidEscape header var =
  do  (Descriptor content rank _ _) <- UF.get var
      if rank == noRank
        then return []
        else
          case Map.toList header of
            [] ->
              $(Crash.crashIO 'rigidEscape) "rigid variable escaped from a let with no annotated names"

            (name, A.At region _) : _ ->
              return [ Error.RigidEscape region name (rigidName content) ]


rigidName :: Content -> String
rigidName content =
  case content of
    RigidVar name -> T.varToChars name
    RigidSuper _ name -> T.varToChars name
    _ -> "a"



-- EXPECTATIONS TO VARIABLE


expectedToVariable :: Int -> Pools -> Error.Expected Type -> IO Variable
expectedToVariable rank pools expectation =
  typeToVariable rank pools $
    case expectation of
      Error.NoExpectation tipe ->
        tipe

      Error.FromContext _ _ tipe ->
        tipe

      Error.FromAnnotation _ _ _ tipe ->
        tipe


patternExpectationToVariable :: Int -> Pools -> Error.PExpected Type -> IO Variable
patternExpectationToVariable rank pools expectation =
  typeToVariable rank pools $
    case expectation of
      Error.PNoExpectation tipe ->
        tipe

      Error.PFromContext _ _ tipe ->
        tipe



-- ERROR HELPERS


-- Ficcus (ATTACH A3): a mismatch that involves a custom type with well known members says what is missing
noted :: State -> ET.Type -> ET.Type -> Error.Error -> Error.Error
noted state actualType expectedType err =
  case Members.notesFor (_table state) actualType expectedType of
    [] -> err
    notes -> Error.WithNotes err notes


addError :: State -> Error.Error -> State
addError state err =
  state { _errors = err : _errors state }


-- Ficcus (ATTACH A3): the type of a use of a name or operator; `/`, `//`, `modBy` and `remainderBy` are typed `a -> a -> a` with an
-- obligation when a type in sight has the member behind them (Type.Members.relax)
instantiateUse :: Int -> Pools -> State -> A.Region -> ModuleName.Canonical -> N.Name -> Map.Map T.Var () -> Can.Type -> IO (Variable, State)
instantiateUse rank pools state region home name freeVars srcType =
  case Members.relax (_table state) home (N.toChars name) srcType of
    Nothing ->
      do  actual <- srcTypeToVariable rank pools freeVars srcType
          return (actual, state)

    Just (member, defaultType) ->
      do  let Can.Forall vars shape = Members.relaxedUse
          pair <- srcTypeToVariable rank pools vars shape
          (Descriptor content _ _ _) <- UF.get pair
          case content of
            Structure (Pair1 subject fn) ->
              return (fn, state { _pending = Members.relaxedObligation region name member subject fn defaultType : _pending state })

            _ ->
              return (pair, state)


-- Ficcus (ATTACH A2): discharge the member obligations whose subject is known by now (Type.Members)
discharge :: Env -> Int -> Pools -> State -> IO State
discharge env rank pools state =
  case _pending state of
    [] ->
      return state

    pending ->
      do  let tools =
                Members.Tools
                  (\(Can.Forall freeVars srcType) -> srcTypeToVariable rank pools freeVars srcType)
                  (introduce rank pools)
                  (Members.policyOf (_flag state) (_table state))
                  (maybe (return ()) (\ref -> writeIORef ref True) (_flag state))
          (pending1, errors) <- Members.discharge tools (_table state) env pending
          -- (A5a, D9) one type per member name per variable
          (pending', errors') <- Requirements.improve tools pending1
          return (state { _pending = pending', _errors = errors' ++ errors ++ _errors state })



-- OCCURS CHECK


occurs :: State -> (N.Name, A.Located Variable) -> IO State
occurs state (name, A.At region variable) =
  do  hasOccurred <- Occurs.occurs variable
      if hasOccurred
        then
          do  errorType <- Type.toErrorType variable
              (Descriptor _ rank mark copy) <- UF.get variable
              UF.set variable (Descriptor Error rank mark copy)
              return $ addError state (Error.InfiniteType region name errorType)
        else
          return state



-- GENERALIZE


{-| Every variable has rank less than or equal to the maxRank of the pool.
This sorts variables into the young and old pools accordingly.
-}
generalize :: Mark -> Mark -> Mark -> Int -> Pools -> IO Bool
generalize youngMark visitMark grayMark youngRank pools =
  do  youngVars <- MVector.read pools youngRank
      rankTable <- poolToRankTable youngMark youngRank youngVars
      cycleRef <- newIORef False

      -- get the ranks right for each entry.
      -- start at low ranks so that we only have to pass
      -- over the information once.
      Vector.imapM_
        (\rank table -> mapM_ (adjustRank youngMark visitMark grayMark cycleRef rank) table)
        rankTable

      -- For variables that have rank lowerer than youngRank, register them in
      -- the appropriate old pool if they are not redundant.
      Vector.forM_ (Vector.unsafeInit rankTable) $ \vars ->
        forM_ vars $ \var ->
          do  isRedundant <- UF.redundant var
              if isRedundant
                then return ()
                else
                  do  (Descriptor _ rank _ _) <- UF.get var
                      MVector.modify pools (var:) rank

      -- For variables with rank youngRank
      --   If rank < youngRank: register in oldPool
      --   otherwise generalize
      forM_ (Vector.unsafeLast rankTable) $ \var ->
        do  isRedundant <- UF.redundant var
            if isRedundant
              then return ()
              else
                do  (Descriptor content rank mark copy) <- UF.get var
                    if rank < youngRank
                      then MVector.modify pools (var:) rank
                      else UF.set var $ Descriptor content noRank mark copy

      readIORef cycleRef


-- | (A5a) the rank adjustment of `generalize` alone: afterwards every variable of the young pool has its true rank
-- (Type.Requirements decides by it); the pools are not changed, and `generalize` runs it again with new marks
adjustRanks :: Mark -> Mark -> Mark -> Int -> Pools -> IO ()
adjustRanks youngMark visitMark grayMark youngRank pools =
  do  youngVars <- MVector.read pools youngRank
      rankTable <- poolToRankTable youngMark youngRank youngVars
      cycleRef <- newIORef False
      Vector.imapM_
        (\rank table -> mapM_ (adjustRank youngMark visitMark grayMark cycleRef rank) table)
        rankTable


poolToRankTable :: Mark -> Int -> [Variable] -> IO (Vector.Vector [Variable])
poolToRankTable youngMark youngRank youngInhabitants =
  do  mutableTable <- MVector.replicate (youngRank + 1) []

      -- Sort the youngPool variables into buckets by rank.
      forM_ youngInhabitants $ \var ->
        do  (Descriptor content rank _ copy) <- UF.get var
            UF.set var (Descriptor content rank youngMark copy)
            MVector.modify mutableTable (var:) rank

      Vector.unsafeFreeze mutableTable



-- ADJUST RANK

--
-- Adjust variable ranks such that ranks never increase as you move deeper.
-- This way the outermost rank is representative of the entire structure.
--
adjustRank :: Mark -> Mark -> Mark -> IORef Bool -> Int -> Variable -> IO Int
adjustRank youngMark visitMark grayMark cycleRef groupRank var =
  do  (Descriptor content rank mark copy) <- UF.get var
      if mark == youngMark then
          do  -- Set the variable as marked first because it may be cyclic. It is gray while its
              -- content is visited: meeting a gray variable again is a cycle (Ficcus D10: the occurs
              -- check only looked at the types of the definitions, not at all variables).
              UF.set var $ Descriptor content rank grayMark copy
              maxRank <- adjustRankContent youngMark visitMark grayMark cycleRef groupRank content
              UF.set var $ Descriptor content maxRank visitMark copy
              return maxRank

        else if mark == grayMark then
          do  writeIORef cycleRef True
              return rank

        else if mark == visitMark then
          return rank

        else
          do  let minRank = min groupRank rank
              -- TODO how can minRank ever be groupRank?
              UF.set var $ Descriptor content minRank visitMark copy
              return minRank


adjustRankContent :: Mark -> Mark -> Mark -> IORef Bool -> Int -> Content -> IO Int
adjustRankContent youngMark visitMark grayMark cycleRef groupRank content =
  let
    go = adjustRank youngMark visitMark grayMark cycleRef groupRank
  in
    case content of
      FlexVar _ ->
          return groupRank

      FlexSuper _ _ ->
          return groupRank

      RigidVar _ ->
          return groupRank

      RigidSuper _ _ ->
          return groupRank

      Structure flatType ->
        case flatType of
          App1 _ _ args ->
            foldM (\rank arg -> max rank <$> go arg) outermostRank args

          Fun1 arg result ->
              max <$> go arg <*> go result

          EmptyRecord1 ->
              -- THEORY: an empty record never needs to get generalized
              return outermostRank

          Record1 fields extension ->
              do  extRank <- go extension
                  foldM (\rank field -> max rank <$> go field) extRank fields

          Unit1 ->
              -- THEORY: a unit never needs to get generalized
              return outermostRank

          Pair1 a b ->
              do  ma <- go a
                  mb <- go b
                  return $ max ma mb

          Triple1 a b c ->
              do  ma <- go a
                  mb <- go b
                  mc <- go c
                  return $ max (max ma mb) mc

      Alias _ _ args _ ->
          -- THEORY: anything in the realVar would be outermostRank
          foldM (\rank (_, argVar) -> max rank <$> go argVar) outermostRank args

      Error ->
          return groupRank



-- REGISTER VARIABLES


introduce :: Int -> Pools -> [Variable] -> IO ()
introduce rank pools variables =
  do  MVector.modify pools (variables++) rank
      forM_ variables $ \var ->
        UF.modify var $ \(Descriptor content oldRank mark copy) ->
          Descriptor content (if oldRank == noRank then rank else min oldRank rank) mark copy



-- TYPE TO VARIABLE


typeToVariable :: Int -> Pools -> Type -> IO Variable
typeToVariable rank pools tipe =
  typeToVar rank pools Map.empty tipe


-- PERF working with @mgriffith we noticed that a 784 line entry in a `let` was
-- causing a ~1.5 second slowdown. Moving it to the top-level to be a function
-- saved all that time. The slowdown seems to manifest in `typeToVar` and in
-- `register` in particular. Have not explored further yet. Top-level definitions
-- are recommended in cases like this anyway, so there is at least a safety
-- valve for now.
--
typeToVar :: Int -> Pools -> Map.Map T.Var Variable -> Type -> IO Variable
typeToVar rank pools aliasDict tipe =
  let go = typeToVar rank pools aliasDict in
  case tipe of
    VarN v ->
      return v

    AppN home name args ->
      do  argVars <- traverse go args
          register rank pools (Structure (App1 home name argVars))

    FunN a b ->
      do  aVar <- go a
          bVar <- go b
          register rank pools (Structure (Fun1 aVar bVar))

    AliasN home name args aliasType ->
      do  argVars <- traverse (traverse go) args
          aliasVar <- typeToVar rank pools (Map.fromList argVars) aliasType
          register rank pools (Alias home name argVars aliasVar)

    PlaceHolder name ->
      return $ $(Map.require 'typeToVar) name aliasDict T.varToChars

    RecordN fields ext ->
      do  fieldVars <- traverse go fields
          extVar <- go ext
          register rank pools (Structure (Record1 fieldVars extVar))

    EmptyRecordN ->
      register rank pools emptyRecord1

    UnitN ->
      register rank pools unit1

    PairN a b ->
      do  aVar <- go a
          bVar <- go b
          register rank pools (Structure (Pair1 aVar bVar))

    TripleN a b c ->
      do  aVar <- go a
          bVar <- go b
          cVar <- go c
          register rank pools (Structure (Triple1 aVar bVar cVar))


register :: Int -> Pools -> Content -> IO Variable
register rank pools content =
  do  var <- UF.fresh (Descriptor content rank noMark Nothing)
      MVector.modify pools (var:) rank
      return var


{-# NOINLINE emptyRecord1 #-}
emptyRecord1 :: Content
emptyRecord1 =
  Structure EmptyRecord1


{-# NOINLINE unit1 #-}
unit1 :: Content
unit1 =
  Structure Unit1



-- SOURCE TYPE TO VARIABLE


srcTypeToVariable :: Int -> Pools -> Map.Map T.Var () -> Can.Type -> IO Variable
srcTypeToVariable rank pools freeVars srcType =
  let
    nameToContent name@(T.Var _ con) =
      case con of
        T.Number     -> FlexSuper Number (Just name)
        T.Comparable -> FlexSuper Comparable (Just name)
        T.Appendable -> FlexSuper Appendable (Just name)
        T.CompAppend -> FlexSuper CompAppend (Just name)
        T.Any        -> FlexVar (Just name)

    makeVar name _ =
      UF.fresh (Descriptor (nameToContent name) rank noMark Nothing)
  in
  do  flexVars <- Map.traverseWithKey makeVar freeVars
      MVector.modify pools (Map.elems flexVars ++) rank
      srcTypeToVar rank pools flexVars srcType


srcTypeToVar :: Int -> Pools -> Map.Map T.Var Variable -> Can.Type -> IO Variable
srcTypeToVar rank pools flexVars srcType =
  let go = srcTypeToVar rank pools flexVars in
  case srcType of
    Can.TLambda argument result ->
      do  argVar <- go argument
          resultVar <- go result
          register rank pools (Structure (Fun1 argVar resultVar))

    Can.TVar name ->
      return $ $(Map.require 'srcTypeToVar) name flexVars T.varToChars

    Can.TType home name args ->
      do  argVars <- traverse go args
          register rank pools (Structure (App1 home name argVars))

    Can.TRecord fields maybeExt ->
      do  fieldVars <- traverse (srcFieldTypeToVar rank pools flexVars) fields
          extVar <-
            case maybeExt of
              Nothing -> register rank pools emptyRecord1
              Just ext -> return $ $(Map.require 'srcTypeToVar) ext flexVars T.varToChars
          register rank pools (Structure (Record1 fieldVars extVar))

    Can.TUnit ->
      register rank pools unit1

    Can.TPair a b ->
      do  aVar <- go a
          bVar <- go b
          register rank pools (Structure (Pair1 aVar bVar))

    Can.TTriple a b c ->
      do  aVar <- go a
          bVar <- go b
          cVar <- go c
          register rank pools (Structure (Triple1 aVar bVar cVar))

    Can.TAlias home name args aliasType ->
      do  argVars <- traverse (traverse go) args
          aliasVar <-
            case aliasType of
              Can.Holey tipe ->
                srcTypeToVar rank pools (Map.fromList argVars) tipe

              Can.Filled tipe ->
                go tipe

          register rank pools (Alias home name argVars aliasVar)


srcFieldTypeToVar :: Int -> Pools -> Map.Map T.Var Variable -> Can.FieldType -> IO Variable
srcFieldTypeToVar rank pools flexVars (Can.FieldType _ srcTipe) =
  srcTypeToVar rank pools flexVars srcTipe



-- COPY


makeCopy :: Int -> Pools -> Variable -> IO Variable
makeCopy rank pools var =
  do  copy <- makeCopyHelp rank pools var
      restore var
      return copy


makeCopyHelp :: Int -> Pools -> Variable -> IO Variable
makeCopyHelp maxRank pools variable =
  do  (Descriptor content rank _ maybeCopy) <- UF.get variable

      case maybeCopy of
        Just copy ->
          return copy

        Nothing ->
          if rank /= noRank then
            return variable

          else
            do  let makeDescriptor c = Descriptor c maxRank noMark Nothing
                copy <- UF.fresh $ makeDescriptor content
                MVector.modify pools (copy:) maxRank

                -- Link the original variable to the new variable. This lets us
                -- avoid making multiple copies of the variable we are instantiating.
                --
                -- Need to do this before recursively copying to avoid looping.
                UF.set variable $
                  Descriptor content rank noMark (Just copy)

                -- Now we recursively copy the content of the variable.
                -- We have already marked the variable as copied, so we
                -- will not repeat this work or crawl this variable again.
                case content of
                  Structure term ->
                    do  newTerm <- traverseFlatType (makeCopyHelp maxRank pools) term
                        UF.set copy $ makeDescriptor (Structure newTerm)
                        return copy

                  FlexVar _ ->
                    return copy

                  FlexSuper _ _ ->
                    return copy

                  RigidVar name ->
                    do  UF.set copy $ makeDescriptor $ FlexVar (Just name)
                        return copy

                  RigidSuper super name ->
                    do  UF.set copy $ makeDescriptor $ FlexSuper super (Just name)
                        return copy

                  Alias home name args realType ->
                    do  newArgs <- mapM (traverse (makeCopyHelp maxRank pools)) args
                        newRealType <- makeCopyHelp maxRank pools realType
                        UF.set copy $ makeDescriptor (Alias home name newArgs newRealType)
                        return copy

                  Error ->
                    return copy



-- RESTORE


restore :: Variable -> IO ()
restore variable =
  do  (Descriptor content _ _ maybeCopy) <- UF.get variable
      case maybeCopy of
        Nothing ->
          return ()

        Just _ ->
          do  UF.set variable $ Descriptor content noRank noMark Nothing
              restoreContent content


restoreContent :: Content -> IO ()
restoreContent content =
  case content of
    FlexVar _ ->
      return ()

    FlexSuper _ _ ->
      return ()

    RigidVar _ ->
      return ()

    RigidSuper _ _ ->
      return ()

    Structure term ->
      case term of
        App1 _ _ args ->
          mapM_ restore args

        Fun1 arg result ->
          do  restore arg
              restore result

        EmptyRecord1 ->
          return ()

        Record1 fields ext ->
          do  mapM_ restore fields
              restore ext

        Unit1 ->
          return ()

        Pair1 a b ->
          do  restore a
              restore b

        Triple1 a b c ->
          do  restore a
              restore b
              restore c

    Alias _ _ args var ->
      do  mapM_ (traverse restore) args
          restore var

    Error ->
        return ()



-- TRAVERSE FLAT TYPE


traverseFlatType :: (Variable -> IO Variable) -> FlatType -> IO FlatType
traverseFlatType f flatType =
  case flatType of
    App1 home name args ->
        liftM (App1 home name) (traverse f args)

    Fun1 a b ->
        liftM2 Fun1 (f a) (f b)

    EmptyRecord1 ->
        pure EmptyRecord1

    Record1 fields ext ->
        liftM2 Record1 (traverse f fields) (f ext)

    Unit1 ->
        pure Unit1

    Pair1 a b ->
        liftM2 Pair1 (f a) (f b)

    Triple1 a b c ->
        liftM3 Triple1 (f a) (f b) (f c)
