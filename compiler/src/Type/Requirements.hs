{-# LANGUAGE PatternGuards #-}
-- Ficus (A5a): inference of requirements (`a has m : t`) for definitions without a type annotation, and let
-- generalization over them.  docs/A5-INFERENCE-DESIGN.md sections 1 and 3; decisions D1 to D4, D9.
--
-- Type.Members keeps the obligations (requirements of the uses) and discharges them when a subject is known.  This
-- module decides, at each generalization, what happens to the obligations that are still pending:
--
--   * determined by an outer variable (the closure under rule 3 from the context): held, the variables keep the
--     context's rank (the precise form of the 56bb4fd0 hold)
--   * an untyped function (arguments or a lambda body, D4) whose type determines the subject: the requirement goes
--     into its scheme, packed with the type in a carrier (`$where type $inferred ($has$m s t) ...`)
--   * anything else in a `let` (a value, the monomorphism restriction, or an undetermined subject): held
--   * anything else at the top level: an undetermined `number` subject (or one of a relaxed operator or Float
--     literal) defaults to Int or Float (D3); what is left is an error (Type.Members.hold's report)
--
-- Rule 1 (D9, one type per name per variable): two obligations `a has m : t1` and `a has m : t2` unify t1 ~ t2.
--
-- An Elm program has no pending obligation at any generalization, so none of this runs for it.
module Type.Requirements
  ( Kind(..)
  , Kinds
  , kindsOf
  , kindOfHeader
  , improve
  , Outcome(..)
  , settle
  , carrier
  )
  where


import Control.Monad (foldM, forM, forM_, filterM)
import qualified Data.Map.Strict as Map

import qualified AST.Canonical as Can
import qualified AST.Constraints as Constraints
import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeName as T
import qualified AST.Prim.TypeVar as TV
import qualified AST.WellKnown as WK
import qualified Elm.ModuleName as ModuleName
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Type as Error
import qualified Type.Error as ET
import Type.Members (Obligation(..))
import qualified Type.Members as Members
import Type.Type as Type
import qualified Type.Unify as Unify
import qualified Type.UnionFind as UF



-- WHAT A DEFINITION IS (D4)


-- | a definition by the region of its name: a function (no annotation; arguments, or a lambda body), a value (no
-- annotation, not a function: the monomorphism restriction), or annotated (its scheme is the annotation)
data Kind
  = Function
  | Value
  | Typed [(String, N.Name)]   -- (A5c) the `where` lines of the annotation (variable, member), for INCOMPLETE TYPE ANNOTATION
  deriving (Eq)


type Kinds =
  Map.Map A.Region Kind


kindsOf :: Can.Module -> Kinds
kindsOf (Can.Module _ _ _ decls _ _ _ _) =
  Map.fromList (concatMap defKinds (Members.defsOf decls))


defKinds :: Can.Def -> [(A.Region, Kind)]
defKinds def =
  case def of
    Can.Def (A.At region _) args body ->
      (region, if null args && not (isLambda body) then Value else Function) : exprKinds body

    Can.TypedDef (A.At region _) _ _ body _ ->
      (region, Typed [ (v, m) | Constraints.Hidden v m _ <- Constraints.hiddenOfDef def ]) : exprKinds body
  where
    isLambda (A.At _ e) =
      case e of
        Can.Lambda _ _ -> True
        _ -> False


exprKinds :: Can.Expr -> [(A.Region, Kind)]
exprKinds (A.At _ expr) =
  case expr of
    Can.List xs -> concatMap exprKinds xs
    Can.Negate e -> exprKinds e
    Can.Binop _ _ _ _ l r -> exprKinds l ++ exprKinds r
    Can.Lambda _ e -> exprKinds e
    Can.Call f xs -> concatMap exprKinds (f : xs)
    Can.If branches final -> concat [ exprKinds c ++ exprKinds b | (c, b) <- branches ] ++ exprKinds final
    Can.Let def body -> defKinds def ++ exprKinds body
    Can.LetRec defs body -> concatMap defKinds defs ++ exprKinds body
    Can.LetDestruct _ e body -> exprKinds e ++ exprKinds body
    Can.Case e branches -> exprKinds e ++ concat [ exprKinds b | Can.CaseBranch _ b <- branches ]
    Can.Access e _ -> exprKinds e
    Can.Update _ e fields -> exprKinds e ++ concat [ exprKinds b | Can.FieldUpdate _ b <- Map.elems fields ]
    Can.Record fields -> concatMap exprKinds (Map.elems fields)
    Can.Pair a b -> exprKinds a ++ exprKinds b
    Can.Triple a b c -> exprKinds a ++ exprKinds b ++ exprKinds c
    _ -> []


-- | the kind of the definitions of a let (a recursive group is a function group only when every member is a
-- function, as the monomorphism restriction of Haskell); a header that is not a definition (the variables of the
-- patterns of arguments, of `let ( a, b ) = ...`) counts as a value
kindOfHeader :: Kinds -> Map.Map N.Name (A.Located a) -> Kind
kindOfHeader kinds header =
  case [ Map.lookup region kinds | A.At region _ <- Map.elems header ] of
    [] -> Value
    ks | t : _ <- [ k | Just k@(Typed _) <- ks ] -> t
       | all (== Just Function) ks -> Function
       | otherwise -> Value



-- RULE 1: ONE TYPE PER NAME PER VARIABLE (D9)


-- | `a has m : t1` and `a has m : t2` on one flexible variable: unify t1 ~ t2 and keep one of them
improve :: Members.Tools -> [Obligation] -> IO ([Obligation], [Error.Error])
improve tools pending =
  case pending of
    [] -> return ([], [])
    [_] -> return (pending, [])
    _ ->
      do  (kept, errors) <- foldM step ([], []) pending
          return (reverse kept, errors)
  where
    step (kept, errors) o =
      do  flex <- isFlex (_subject o)
          if not flex then return (o : kept, errors) else
            do  same <- findM (\k -> if _member k /= _member o then return False else UF.equivalent (_subject k) (_subject o)) kept
                case same of
                  Nothing ->
                    return (o : kept, errors)

                  Just k ->
                    do  answer <- Unify.unifyWith (Members._policy tools) (_type k) (_type o)
                        let k' = k { _default = maybe (_default o) Just (_default k) }
                        let kept' = map (\x -> if sameObligation x k then k' else x) kept
                        case answer of
                          Unify.Ok vars ->
                            do  Members._introduce tools vars
                                return (kept', errors)

                          Unify.Err vars actual needed ->
                            do  Members._introduce tools vars
                                -- (A5c) the variable by its name in the message (the types are named with it)
                                subject <- Type.toErrorType (_subject o)
                                let var = case subject of { ET.FlexVar n -> TV.varToChars n; ET.FlexSuper _ n -> TV.varToChars n; _ -> "a" }
                                return (kept', Error.BadMember (_region o) (_function o) (_member o) (Error.MemberOfOtherUse var (_region k)) actual needed : errors)

                          Unify.Runaway isCycle ->
                            return (kept', Error.Runaway (_region o) isCycle : errors)

    sameObligation a b =
      _region a == _region b && _member a == _member b && _function a == _function b



findM :: (a -> IO Bool) -> [a] -> IO (Maybe a)
findM p xs =
  case xs of
    [] -> return Nothing
    x : rest -> p x >>= \b -> if b then return (Just x) else findM p rest



-- SETTLING THE PENDING OBLIGATIONS OF A GENERALIZATION


data Outcome =
  Outcome
    { _pending :: [Obligation]   -- still pending: about outer variables, held, or rigid subjects (Members.sweep)
    , _scheme :: [Obligation]    -- go into the scheme of the definitions (Solve builds the carriers)
    , _errors :: [Error.Error]
    }


-- | called with the true ranks (Solve adjusted them before): `outer` is the rank of the context, `young` the rank of
-- the variables the definition would generalize
settle :: Members.Tools -> Members.Table -> Map.Map N.Name Variable -> Kind -> Int -> Int -> Map.Map N.Name (A.Located Variable) -> [Obligation] -> IO Outcome
settle tools table env kind outer young header pending =
  do  youngFlags <- traverse (isYoung young . _subject) pending
      let youngOnes = [ o | (o, True) <- zip pending youngFlags ]
      let others = [ o | (o, False) <- zip pending youngFlags ]
      -- an obligation about an older subject: the context determines its member type, which keeps the context's rank
      -- (B4: `y = get (get w)`)
      olderFlags <- traverse (\o -> (< young) <$> rankOf (_subject o)) others
      forM_ [ o | (o, True) <- zip others olderFlags ] $ \o -> raise outer (_type o)
      if null youngOnes then return (Outcome pending [] []) else
        do  -- the roots: what the context fixes (the member types of obligations about older subjects), and what the
            -- type of the definition fixes (its variables, and the member types of obligations about its own rigid
            -- variables)
            outerRoots <- concat <$> traverse (Members.flexVariables . _type) [ o | (o, True) <- zip others olderFlags ]
            ownRoots <- concat <$> traverse (Members.flexVariables . _type) [ o | (o, False) <- zip others olderFlags ]
            byOuter <- closure outerRoots youngOnes
            -- (A5f, review M2) in a recursive group a requirement goes into the scheme only when the type of every name
            -- determines it (the group shares one context): one that some name's type does not determine is ambiguous for
            -- that name, so it is held in a `let`, defaulted or reported at the top level
            byType <- forM (Map.elems header) $ \(A.At _ var) ->
              do  roots <- Members.flexVariables var
                  closure (roots ++ ownRoots) youngOnes
            classes <- forM youngOnes $ \o ->
              do  held <- memberOf (_subject o) byOuter
                  typed <- and <$> traverse (memberOf (_subject o)) byType
                  return $
                    if held then Hold
                    else if kind == Function && typed then Scheme
                    else if outer > outermostRank then Hold
                    else Settle
            let holds = [ o | (o, Hold) <- zip youngOnes classes ]
            forM_ holds $ \o -> raise outer (_subject o) >> raise outer (_type o)
            -- no requirement is quantified while its subject is held: a scheme obligation whose subject a hold reached
            -- is held too (its variables then keep the context's rank); to a fixpoint, since a demoted obligation's member
            -- type can reach the subject of another (A5f, review B4)
            (scheme0, demoted) <- demote outer young [ o | (o, Scheme) <- zip youngOnes classes ] []
            -- (A5f, review B1) rule 1 when a requirement goes into a scheme (or is settled at the top level), not at every
            -- discharge: held and pending obligations are left to their discharge, so acceptance does not depend on the
            -- order of independent `let` definitions
            (scheme, improveErrors) <- improve tools scheme0
            (settled, errors) <-
              case [ o | (o, Settle) <- zip youngOnes classes ] of
                [] -> return ([], [])
                candidates0 ->
                  do  (candidates, candidateErrors) <- improve tools candidates0
                      (settled0, errors0) <- defaultAndReport tools table env (kind == Value) young header candidates
                      return (settled0, candidateErrors ++ errors0)
            return (Outcome (others ++ holds ++ demoted ++ settled) scheme (improveErrors ++ errors))


-- | the scheme obligations whose subject is still young; the others are held (raised to `outer`), to a fixpoint
demote :: Int -> Int -> [Obligation] -> [Obligation] -> IO ([Obligation], [Obligation])
demote outer young candidates demoted =
  do  flags <- forM candidates $ \o -> (\r -> (o, r >= young)) <$> rankOf (_subject o)
      case [ o | (o, False) <- flags ] of
        [] -> return (candidates, demoted)
        new ->
          do  forM_ new $ \o -> raise outer (_subject o) >> raise outer (_type o)
              demote outer young [ o | (o, True) <- flags ] (demoted ++ new)


data Class = Hold | Scheme | Settle


isYoung :: Int -> Variable -> IO Bool
isYoung young var =
  do  (Descriptor content rank _ _) <- UF.get var
      return $
        rank >= young &&
          case content of
            FlexVar _ -> True
            FlexSuper _ _ -> True
            _ -> False


isFlex :: Variable -> IO Bool
isFlex var =
  do  (Descriptor content _ _ _) <- UF.get var
      return $
        case content of
          FlexVar _ -> True
          FlexSuper _ _ -> True
          _ -> False


rankOf :: Variable -> IO Int
rankOf var =
  do  (Descriptor _ rank _ _) <- UF.get var
      return rank


memberOf :: Variable -> [Variable] -> IO Bool
memberOf var vars =
  case vars of
    [] -> return False
    v : rest -> UF.equivalent var v >>= \b -> if b then return True else memberOf var rest


-- | the variables that the roots determine (rule 3): the roots, and the member types of the obligations whose subject
-- is determined, to a fixpoint
closure :: [Variable] -> [Obligation] -> IO [Variable]
closure roots obligations =
  loop roots obligations
  where
    loop det remaining =
      do  flags <- traverse (\o -> memberOf (_subject o) det) remaining
          let reached = [ o | (o, True) <- zip remaining flags ]
          let rest = [ o | (o, False) <- zip remaining flags ]
          if null reached then return det else
            do  more <- concat <$> traverse (Members.flexVariables . _type) reached
                loop (det ++ more) rest


-- | every variable of a type that is younger than `outer` gets the rank `outer` (a structure too, so that a
-- generalization cannot quantify a part of a held obligation)
raise :: Int -> Variable -> IO ()
raise outer var =
  do  (Descriptor content rank mark copy) <- UF.get var
      if rank <= outer || rank == noRank then return () else
        do  UF.set var (Descriptor content outer mark copy)
            case content of
              Structure flat -> mapM_ (raise outer) (children flat)
              Alias _ _ args real -> mapM_ (raise outer) (real : map snd args)
              _ -> return ()
  where
    children flat =
      case flat of
        App1 _ _ args -> args
        Fun1 a b -> [a, b]
        EmptyRecord1 -> []
        Record1 fields ext -> ext : Map.elems fields
        Unit1 -> []
        Pair1 a b -> [a, b]
        Triple1 a b c -> [a, b, c]



-- DEFAULTING (D3)


-- | at the top level: an undetermined subject that is a `number` variable, or the subject of a relaxed operator or
-- of a Float literal, becomes Int or Float (Float first when `div` or `fromFloat` is required), if that type has
-- every member required of it.  What is left is reported as Members.hold reports it (MISSING CONSTRAINT when the
-- variables are those of the definition's type, UNKNOWN MEMBER TYPE otherwise).
defaultAndReport :: Members.Tools -> Members.Table -> Map.Map N.Name Variable -> Bool -> Int -> Map.Map N.Name (A.Located Variable) -> [Obligation] -> IO ([Obligation], [Error.Error])
defaultAndReport tools table env isValue young header candidates =
  do  groups <- groupBySubject candidates
      forM_ groups $ \(first, rest) ->
        do  choice <- defaultFor first (first : rest)
            case choice of
              Nothing -> return ()
              Just tipe -> settleTo (_subject first) tipe
      (left, errors) <- Members.discharge tools table env candidates
      stillYoung <- filterM (\o -> (>= young) <$> rankOf (_subject o)) left
      (kept, holdErrors) <- Members.hold table isValue outermostRank young header stillYoung
      let others = [ o | o <- left, not (any (same o) stillYoung) ]
      return (others ++ kept, errors ++ holdErrors)
  where
    same a b = _region a == _region b && _member a == _member b && _function a == _function b

    defaultFor first group =
      do  (Descriptor content _ _ _) <- UF.get (_subject first)
          let members = map (N.toChars . _member) group
          let relaxed = [ t | Just t <- map _default group ]
          let numberish =
                case content of
                  FlexSuper Number _ -> True
                  FlexVar _ -> not (null relaxed)
                  _ -> False
          let floatFirst = any (`elem` ["div", "fromFloat"]) members || any (== floatT) relaxed
          let order = if floatFirst then [(WK.BFloat, floatT), (WK.BInt, intT)] else [(WK.BInt, intT), (WK.BFloat, floatT)]
          return $
            if not numberish then Nothing else
              case [ t | (k, t) <- order, all (WK.builtinHas k) members ] of
                t : _ -> Just t
                [] -> Nothing

    settleTo subject tipe =
      do  var <- Members._instantiate tools (Can.Forall Map.empty tipe)
          answer <- Unify.unifyWith (Members._policy tools) subject var
          case answer of
            Unify.Ok vars -> Members._introduce tools vars
            Unify.Err vars _ _ -> Members._introduce tools vars
            Unify.Runaway _ -> return ()

    floatT = Can.TType ModuleName.basics T.float []
    intT = Can.TType ModuleName.basics T.int []


groupBySubject :: [Obligation] -> IO [(Obligation, [Obligation])]
groupBySubject obligations =
  reverse <$> foldM add [] obligations
  where
    add groups o =
      do  found <- findIndexM (\(first, _) -> UF.equivalent (_subject first) (_subject o)) groups
          return $
            case found of
              Nothing -> (o, []) : groups
              Just i -> [ if j == i then (first, rest ++ [o]) else g | (j, g@(first, rest)) <- zip [0 :: Int ..] groups ]

    findIndexM p xs =
      go 0 xs
      where
        go _ [] = return Nothing
        go i (x : rest) = p x >>= \b -> if b then return (Just i) else go (i + 1) rest



-- THE CARRIER (section 3)


-- | the scheme of one name of the definition: its type and the requirements its type determines, as one variable
-- (`$where type $inferred ($has$m s t) ...`) made at the young rank, so that it is generalized with the definition
-- and a use copies the type and the requirements together (Solve, CLocal; Members.use).  Nothing: no requirement.
carrier :: (Content -> IO Variable) -> Variable -> [Obligation] -> IO (Maybe Variable)
carrier register tipe scheme =
  do  roots <- Members.flexVariables tipe
      determined <- closure roots scheme
      mine <- filterM (\o -> memberOf (_subject o) determined) scheme
      case mine of
        [] -> return Nothing
        _ ->
          do  marker <- register (Structure (App1 ModuleName.basics Constraints.inferredName []))
              entries <- forM mine $ \o ->
                register (Structure (App1 ModuleName.basics (Constraints.hasTypeName (_member o)) [_subject o, _type o]))
              Just <$> register (Structure (App1 ModuleName.basics Constraints.whereName (tipe : marker : entries)))
