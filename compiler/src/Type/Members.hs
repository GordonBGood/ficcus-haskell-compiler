{-# LANGUAGE PatternGuards #-}
-- Ficcus (ATTACH, stage A2): the member obligations of the solver.
--
-- A use of a constrained function (AST.Constraints) leaves, for every `a has m : t` of its scheme, an
-- obligation: the type the variable `a` becomes must have a member `m` of type `t`.  The obligations are
-- kept in a list beside the union-find (nothing in Type.Type, Type.Unify or Type.Occurs knows about them;
-- Elm's `number`, `comparable`, `appendable` variables are not involved).  They are discharged when the
-- subject is known:
--
--   a custom type T       the member `T.m` is looked up in the table, instantiated and unified with `t`
--   a rigid variable `a`  the enclosing definition must have the constraint: its hidden parameter `a$has$m`
--                         is in the environment while its body is solved, and its type is unified with `t`
--   a flexible variable   pending; an error if the variable is generalized (a constraint is never inferred)
--
-- See docs/attach/A2-DESIGN.md, section 2.
module Type.Members
  ( Table
  , emptyTable
  , toTable
  , embedded
  , wrapAnnotations
  , Obligation
  , Tools(..)
  , policyOf
  , shapeErrors
  , notesFor
  , relax
  , relaxedUse
  , relaxedObligation
  , defaulting
  , defsOf
  , nameOf
  , use
  , discharge
  , hold
  , sweep
  , leftovers
  , merge
  )
  where


import Control.Monad (foldM, forM_)
import Data.IORef (IORef, writeIORef)
import qualified Data.Map.Strict as Map

import qualified AST.Canonical as Can
import qualified AST.Constraints as Constraints
import qualified AST.Derive as Derive
import qualified AST.Members as Members
import qualified AST.Prim.Module as Module
import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeName as T
import qualified AST.Prim.TypeVar as TV
import qualified AST.WellKnown as WK
import qualified Elm.Interface as I
import qualified Elm.ModuleName as ModuleName
import qualified Elm.Package as Pkg
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Type as Error
import qualified Type.Error as ET
import Type.Type as Type
import qualified Type.Unify as Unify
import qualified Type.UnionFind as UF
import qualified String as S



-- THE MEMBER TABLE


-- | the members a module can see, by type id (`pkg:Module.Type`, AST.Members.typeId); Nothing: a member of
-- this module without a signature.  A member is found through the module that defines its type (the
-- interface of an import, or the members that an import carries for the types it mentions), so the
-- module that uses a constrained function does not have to import the module of the type.
type Table =
  Map.Map String (Map.Map N.Name (Maybe Can.Annotation))


emptyTable :: Table
emptyTable =
  Map.empty


-- | from the interfaces of the imports (the values `T$$m`, there when the type `T` is exported, with or without `(..)`; and the
-- values `pkg:Module.T$$m` that an interface carries) and the definitions of the module itself
toTable :: Map.Map Module.Name I.Interface -> Can.Module -> Table
toTable ifaces (Can.Module home _ _ decls _ _ _ _) =
  Map.fromListWith Map.union (local ++ imported)
  where
    imported =
      [ (tipeId, Map.singleton member (Just annotation))
      | (name, iface) <- Map.toList ifaces
      , (value, annotation) <- Map.toList (I._values iface)
      , Just (tipe, member) <- [Members.split value]
      , let tipeId = if ':' `elem` tipe then tipe else Members.homeChars (ModuleName.Canonical (I._home iface) name) ++ "." ++ tipe
      ]

    local =
      [ (Members.homeChars home ++ "." ++ tipe, Map.singleton member (annotationOf def))
      | def <- defsOf decls
      , Just (tipe, member) <- [Members.split (nameOf def)]
      ]

    annotationOf def =
      case def of
        Can.Def _ _ _ -> Nothing
        Can.TypedDef _ freeVars args _ result ->
          Just (Constraints.wrapDef def (Can.Forall freeVars (foldr (\(_, t) acc -> Can.TLambda t acc) result args)))


-- | the members of other modules' types that the module saw, as the values an interface can carry
-- (`pkg:Module.T$$m`): Compile adds them to the annotations, `Elm.Interface.fromModule` keeps those that
-- the exports of the module mention
embedded :: Map.Map Module.Name I.Interface -> Map.Map N.Name Can.Annotation
embedded ifaces =
  Map.fromList
    [ (Members.foreignName tipeId member, annotation)
    | (name, iface) <- Map.toList ifaces
    , (value, annotation) <- Map.toList (I._values iface)
    , Just (tipe, member) <- [Members.split value]
    , let tipeId = if ':' `elem` tipe then tipe else Members.homeChars (ModuleName.Canonical (I._home iface) name) ++ "." ++ tipe
    ]


defsOf :: Can.Decls -> [Can.Def]
defsOf decls =
  case decls of
    Can.Declare d rest -> d : defsOf rest
    Can.DeclareRec d more rest -> d : more ++ defsOf rest
    Can.SaveTheEnvironment -> []


nameOf :: Can.Def -> N.Name
nameOf def =
  case def of
    Can.Def (A.At _ n) _ _ -> n
    Can.TypedDef (A.At _ n) _ _ _ _ -> n


-- | the annotations of a module for its interface: a constrained definition (which the type checker
-- sees as a function with hidden parameters) gets its constrained scheme
wrapAnnotations :: Can.Module -> Map.Map N.Name Can.Annotation -> Map.Map N.Name Can.Annotation
wrapAnnotations (Can.Module _ _ _ decls _ _ _ _) annotations =
  foldr wrapOne annotations (defsOf decls)
  where
    wrapOne def acc =
      case Constraints.hiddenOfDef def of
        [] -> acc
        hidden -> Map.adjust (Constraints.wrap hidden) (nameOf def) acc



-- WELL KNOWN MEMBERS (A3)


memberName :: String -> N.Name
memberName =
  N.fromString . S.fromChars


-- | when may a custom type take the place of one of Elm's `number`, `comparable`, `appendable` variables: when
-- it has every member of the bundle, each with the type the language needs
policyOf :: Maybe (IORef Bool) -> Table -> Unify.Policy
policyOf flag table =
  Unify.Policy $ \super home name ->
    let
      allowed =
        case Map.lookup (Members.typeId home name) table of
          Nothing ->
            False

          Just members ->
            all (has members home name) (bundle super)
    in
    do  if allowed then maybe (return ()) (\ref -> writeIORef ref True) flag else return ()
        return allowed
  where
    bundle super =
      case super of
        Number -> WK.numberBundle
        Comparable -> WK.comparableBundle
        Appendable -> WK.appendableBundle
        CompAppend -> WK.comparableBundle ++ WK.appendableBundle

    has members home name member =
      case (Map.lookup (memberName member) members, WK.shapeOf member) of
        (Just (Just (Can.Forall _ written)), Just shape) -> WK.fits home name shape written
        _ -> False


-- | the well known members of this module's own types that do not have the type the language needs, or no
-- type annotation (the members of imported types were checked in their own module)
shapeErrors :: Can.Module -> [Error.Error]
shapeErrors (Can.Module home _ _ decls unions _ _ _) =
  concatMap check (defsOf decls)
  where
    check def =
      case (Members.split (nameOf def), def) of
        (Just (tipe, member), _) | Just shape <- WK.shapeOf (N.toChars member) ->
          let
            tname = T.nameFromString (S.fromChars tipe)
            -- the type with its parameters (`V a`), as the member must be written
            applied = tipe ++ concat [ " " ++ TV.varToChars v | Just u <- [Map.lookup tname unions], v <- Can._u_vars u ]
            expected = WK.expectedText shape applied
          in
          case def of
            Can.Def (A.At region _) _ _ ->
              [Error.WellKnownNoSignature region tipe member expected]

            Can.TypedDef (A.At region _) _ args _ result ->
              let written = foldr (\(_, t) acc -> Can.TLambda t acc) result (drop (Constraints.hiddenCount def) args)
              in
              if (Constraints.hiddenCount def == 0 || derived def) && WK.fits home tname shape written
                then []
                else [Error.WellKnownShape region tipe member expected]

        _ ->
          []

    -- Ficcus (A4a): a derived member (its body is the stub of Canonicalize.Derive) has a synthesized signature, with
    -- `a has m` for the parameters of the type (docs/A4-DERIVE-DESIGN.md, section 1); the A3 rule that a well known
    -- member has no constraints is for written members
    derived def =
      case def of
        Can.TypedDef _ _ _ (A.At _ (Can.VarKernel kernel _)) _ -> S.toChars (Module.kernelToString kernel) == Derive.kernelHome
        _ -> False



-- (A3) `/`, `//`, `modBy` and `remainderBy` are typed by Float and Int in Elm, so a type with the member behind them
-- (`div`, `idiv`, `mod`, `rem`) could not be used.  When a type that this module can see has the member, the use is
-- typed `a -> a -> a` with the obligation `a has <member>`, and Elm's type is the default of `a` (`defaulting`), so
-- every program that uses them on Float and Int means what it meant.  Without such a type nothing changes.
relax :: Table -> ModuleName.Canonical -> String -> Can.Type -> Maybe (N.Name, Can.Type)
relax table home name written =
  case lookup name uses of
    Just (member, tipe)
      | home == ModuleName.basics        -- a user function of the same name is an ordinary one (Elm's own type)
      , written == Can.TLambda tipe (Can.TLambda tipe tipe)
      , any (Map.member (memberName member)) (Map.elems table) ->
          Just (memberName member, tipe)
    _ -> Nothing
  where
    floatT = Can.TType ModuleName.basics T.float []
    intT = Can.TType ModuleName.basics T.int []
    uses = [ ("/", ("div", floatT)), ("//", ("idiv", intT)), ("modBy", ("mod", intT)), ("remainderBy", ("rem", intT)) ]


relaxedObligation :: A.Region -> N.Name -> N.Name -> Variable -> Variable -> Can.Type -> Obligation
relaxedObligation region function member subject tipe defaultType =
  Obligation region function member subject tipe (Just defaultType)


-- | the scheme `(a, a -> a -> a)` of a relaxed use: one instantiation gives the subject and the type of the use
relaxedUse :: Can.Annotation
relaxedUse =
  WK.shapeAnnotation WK.Binary


-- | before the generalization of a top level definition: a subject of a relaxed use that is still a variable gets
-- Elm's type (Float for `/`, Int for the others), and what that settles is discharged
defaulting :: Tools -> Table -> Map.Map N.Name Variable -> Int -> Int -> [Obligation] -> IO ([Obligation], [Error.Error])
defaulting tools table env outer young pending
  | outer > outermostRank || all (\o -> _default o == Nothing) pending = return (pending, [])
  | otherwise =
      do  forM_ pending $ \(Obligation _ _ _ subject _ relaxed) ->
            case relaxed of
              Nothing -> return ()
              Just tipe ->
                do  (Descriptor content rank _ _) <- UF.get subject
                    case content of
                      FlexVar _ | rank >= young -> settle subject tipe
                      FlexSuper _ _ | rank >= young -> settle subject tipe
                      _ -> return ()
          discharge tools table env pending
  where
    settle subject tipe =
      do  var <- _instantiate tools (Can.Forall Map.empty tipe)
          answer <- Unify.unifyWith (_policy tools) subject var
          case answer of
            Unify.Ok vars -> _introduce tools vars
            Unify.Err vars _ _ -> _introduce tools vars
            Unify.Runaway _ -> return ()



-- | (A3) what to add to a type mismatch that involves a custom type with well known members: a `number`, `comparable` or
-- `appendable` that it does not fully have, or an `Int` or `Float` that meets it.  Nothing is added for a type
-- that has no well known member (an ordinary Elm mistake keeps Elm's message).
notesFor :: Table -> ET.Type -> ET.Type -> [String]
notesFor table actual expected =
  notes actual expected ++ notes expected actual
  where
    notes a b =
      case (strip a, strip b) of
        (ET.Type home name _, ET.FlexSuper super _) | Just (shown, _, have) <- membersOf home name ->
          let
            (what, required) = bundleOf super
            missing = [ m | m <- required, m `notElem` have ]
          in
          if null missing || null have
            then []
            else
              [ "`" ++ shown ++ "` can be used as a `" ++ what ++ "` when it defines all the members of `" ++ what ++ "` ("
                ++ commas required ++ ") with the types the language needs. It is missing: " ++ commas missing ++ "." ]

        (ET.Type home name _, ET.Type ohome oname _) | isIntOrFloat ohome oname, Just (shown, _, have) <- membersOf home name, all (`elem` have) WK.numberBundle ->
          [ "`" ++ shown ++ "` and `" ++ T.nameToChars oname ++ "` do not mix: there is no automatic conversion."
            ++ (if oname == T.int then " `" ++ shown ++ ".fromInt` makes a `" ++ shown ++ "` from an `Int`." else "") ]

        _ -> []

    strip t =
      case t of
        ET.Alias _ _ _ real -> strip real
        _ -> t

    isIntOrFloat home name =
      home == ModuleName.basics && (name == T.int || name == T.float)

    -- the members of the type that count: well known names with the type the language needs
    membersOf home name =
      case Map.lookup (Members.typeId home name) table of
        Nothing -> Nothing
        Just members ->
          let
            have =
              [ m
              | (member, Just (Can.Forall _ written)) <- Map.toList members
              , let m = N.toChars member
              , Just shape <- [WK.shapeOf m]
              , WK.fits home name shape written
              ]
          in
          if null have then Nothing else Just (T.nameToChars name, (), have)

    bundleOf super =
      case super of
        ET.Number -> ("number", WK.numberBundle)
        ET.Comparable -> ("comparable", WK.comparableBundle)
        ET.Appendable -> ("appendable", WK.appendableBundle)
        ET.CompAppend -> ("compappend", WK.comparableBundle ++ WK.appendableBundle)

    commas xs =
      case xs of
        [] -> ""
        [x] -> "`" ++ x ++ "`"
        _ -> concatMap (++ ", ") (map (\x -> "`" ++ x ++ "`") (init xs)) ++ "`" ++ last xs ++ "`"


-- OBLIGATIONS


data Obligation =
  Obligation
    { _region :: A.Region
    , _function :: N.Name     -- the constrained function that was used
    , _member :: N.Name
    , _subject :: Variable
    , _type :: Variable
    , _default :: Maybe Can.Type   -- (A3) the type of Elm that a flexible subject gets (`Float` for `/`): see `relax`
    }


-- | what the solver lends: instantiate an annotation at the current rank, register the variables that a
-- unification made
data Tools =
  Tools
    { _instantiate :: Can.Annotation -> IO Variable
    , _introduce :: [Variable] -> IO ()
    , _policy :: Unify.Policy
    , _note :: IO ()             -- (A3) a custom type met an operator that is not typed by `number` (the JavaScript output refuses the program)
    }


-- | the instance of a constrained scheme: its real type and the obligations of this use
use :: A.Region -> N.Name -> Variable -> IO (Variable, [Obligation])
use region function instance_ =
  do  (Descriptor content _ _ _) <- UF.get instance_
      case content of
        Structure (App1 _ name (real : required)) | name == Constraints.whereName ->
          do  obligations <- traverse toObligation required
              return (real, concat obligations)

        _ ->
          return (instance_, [])
  where
    toObligation var =
      do  (Descriptor content _ _ _) <- UF.get var
          case content of
            Structure (App1 _ name [subject, tipe]) | Just member <- Constraints.hasMember name ->
              return [Obligation region function member subject tipe Nothing]

            _ ->
              return []


data Step
  = Keep
  | Done [Obligation] [Error.Error]


-- | discharge what can be discharged now, to a fixpoint: the obligations still pending, and the errors
discharge :: Tools -> Table -> Map.Map N.Name Variable -> [Obligation] -> IO ([Obligation], [Error.Error])
discharge tools table env pending =
  loop pending []
  where
    loop obligations errors =
      do  (kept, new, errors', progress) <- foldM step ([], [], errors, False) obligations
          let next = reverse kept ++ new
          if progress && not (null next)
            then loop next errors'
            else return (next, errors')

    step (kept, new, errors, progress) obligation =
      do  result <- resolve tools table env obligation
          case result of
            Keep -> return (obligation : kept, new, errors, progress)
            Done more errs -> return (kept, more ++ new, errs ++ errors, True)


resolve :: Tools -> Table -> Map.Map N.Name Variable -> Obligation -> IO Step
resolve tools table env obligation@(Obligation region function member subject tipe relaxed) =
  go subject
  where
    policy = _policy tools

    go var =
      do  (Descriptor content _ _ _) <- UF.get var
          case content of
            Structure (App1 home name args) ->
              case Map.lookup (Members.typeId home name) table of
                Just members | Just entry <- Map.lookup member members ->
                  case entry of
                    Just annotation ->
                      do  instance_ <- _instantiate tools annotation
                          (real, more) <- use region function instance_
                          case relaxed of
                            Just _ -> _note tools
                            Nothing -> return ()
                          unify (Error.MemberOfType (T.nameToChars name)) real more

                    Nothing ->
                      return (Done [] [Error.MemberNeedsSignature region function member (T.nameToChars name)])

                maybeMembers
                  | Just kind <- WK.builtinOfApp home name (length args) ->
                      builtin kind (T.nameToChars name) args
                  | isBuiltin home ->
                      builtin WK.BOther (T.nameToChars name) []
                  | N.toChars member == "eq" ->
                      -- `==` is automatic for a type without an `eq` member: the structural equality
                      shaped WK.Equal (T.nameToChars name) []
                  | otherwise ->
                      noMember False (maybe [] Map.keys maybeMembers)

            Structure (Pair1 a b) ->
              builtin WK.BTuple "tuple" [a, b]

            Structure (Triple1 a b c) ->
              builtin WK.BTuple "tuple" [a, b, c]

            Structure Unit1 ->
              builtin WK.BOther "()" []

            Structure (Record1 _ _) ->
              builtin WK.BOther "record" []

            Structure EmptyRecord1 ->
              builtin WK.BOther "record" []

            Structure (Fun1 _ _) ->
              noMember True []

            Alias _ _ _ real ->
              go real

            RigidVar name ->
              given (TV.varToChars name)

            RigidSuper _ name ->
              given (TV.varToChars name)

            FlexVar _ ->
              return Keep

            FlexSuper _ _ ->
              return Keep

            Error ->
              return (Done [] [])

    given var =
      case Map.lookup (Constraints.marker var member) env of
        Just hidden -> unify (Error.MemberOfVariable var) hidden []
        Nothing -> return Keep

    -- (A3) a built-in type has the well known members its type allows; the parts of a list or a tuple must have
    -- `compare` too
    builtin kind tname parts =
      case WK.shapeOf (N.toChars member) of
        Just shape | WK.builtinHas kind (N.toChars member) ->
          shaped shape tname (if WK.builtinChildren kind (N.toChars member) then parts else [])

        _ ->
          noMember True []

    -- the member must have the shape the language needs, at the subject type
    shaped shape tname parts =
      do  inst <- _instantiate tools (WK.shapeAnnotation shape)
          (x, body) <- splitPair inst
          answer <- Unify.unifyWith policy subject x
          case answer of
            Unify.Ok vars ->
              do  _introduce tools vars
                  children <- traverse (child shape) parts
                  unify' (Error.MemberOfType tname) body (concat children)
            Unify.Err vars _ _ ->
              do  _introduce tools vars
                  noMember True []
            Unify.Runaway isCycle ->
              return (Done [] [Error.Runaway region isCycle])

    child shape part =
      do  inst <- _instantiate tools (WK.shapeAnnotation shape)
          (_, body) <- splitPair inst
          return [Obligation region function member part body Nothing]

    splitPair var =
      do  (Descriptor content _ _ _) <- UF.get var
          case content of
            Structure (Pair1 a b) -> return (a, b)
            _ -> return (var, var)

    unify owner actual more =
      unify' owner actual more

    unify' owner actual more =
      do  answer <- Unify.unifyWith policy actual tipe
          case answer of
            Unify.Ok vars ->
              do  _introduce tools vars
                  return (Done more [])

            Unify.Err vars actualType neededType ->
              do  _introduce tools vars
                  return (Done [] [Error.BadMember region function member owner actualType neededType])

            Unify.Runaway isCycle ->
              return (Done [] [Error.Runaway region isCycle])

    noMember builtin' members =
      do  subjectType <- Type.toErrorType subject
          neededType <- Type.toErrorType tipe
          return (Done [] [Error.NoMember region function subjectType members builtin' [(member, neededType)]])

    -- the types of the packages by `elm` (core, json, ...) are the built-in ones
    isBuiltin (ModuleName.Canonical pkg _) =
      take 4 (Pkg.toChars pkg) == "elm/"
      where _ = obligation


-- | before the generalization of a definition (`outer` is the rank of its context, `young` the rank of the
-- variables it would generalize, `header` the names it defines with their types).  Called after the
-- obligations that can be discharged were.
--
--   * a local definition (`let`): the variables that the pending obligations are about (the subjects and the
--     variables of the member types) are not generalized: they get the rank of the context, so the definition
--     is monomorphic in them and they are settled by the enclosing definition, where the obligations are
--     discharged when the type of the subject is known, whatever the order of the source.
--   * a top level definition: a pending obligation about a variable that would be generalized is an error.
--     When the variable occurs in the type of the definition it is MISSING CONSTRAINT, with the type
--     annotation to write; otherwise UNKNOWN MEMBER TYPE.
hold :: Int -> Int -> Map.Map N.Name (A.Located Variable) -> [Obligation] -> IO ([Obligation], [Error.Error])
hold outer young header pending
  | null pending = return ([], [])
  | outer > outermostRank =
      do  forM_ pending $ \(Obligation _ _ _ subject tipe _) ->
            do  vars <- flexVariables subject
                vars2 <- flexVariables tipe
                forM_ (vars ++ vars2) $ \var ->
                  do  (Descriptor content rank mark copy) <- UF.get var
                      if rank >= young then UF.set var (Descriptor content outer mark copy) else return ()
          return (pending, [])
  | otherwise =
      do  flags <- traverse isYoung pending
          let bad = [ o | (o, True) <- zip pending flags ]
          let ok = [ o | (o, False) <- zip pending flags ]
          if null bad then return (pending, []) else
            do  errors <- report (reverse bad)
                return (ok, errors)
  where
    isYoung (Obligation _ _ _ subject _ _) =
      do  (Descriptor content rank _ _) <- UF.get subject
          return $
            case content of
              FlexVar _ -> rank >= young
              FlexSuper _ _ -> rank >= young
              _ -> False

    report bad =
      nameTogether (concat [ [subject, tipe] | Obligation _ _ _ subject tipe _ <- bad ] ++ map A.toValue (Map.elems header)) >>
      report' bad

    report' bad =
      case Map.toList header of
        [] -> traverse unknown bad
        (name, A.At region defVar) : _ ->
          do  defVars <- flexVariables defVar
              -- only an obligation whose variables are all variables of the type of the definition can be written as a constraint
              inDef <- traverse (\o -> do vars <- (++) <$> flexVariables (_subject o) <*> flexVariables (_type o)
                                          allM (\v -> anyM (UF.equivalent v) defVars) vars) bad
              let shown = [ o | (o, True) <- zip bad inDef ]
              let hidden = [ o | (o, False) <- zip bad inDef ]
              missing <-
                case shown of
                  [] -> return []
                  Obligation _ function _ _ _ _ : _ ->
                    do  defType <- Type.toErrorType defVar      -- first: it names the variables that the constraints then use
                        groups <- traverse describe shown
                        return [Error.MissingSignature region function name defType (group groups)]
              others <- traverse unknown hidden
              return (missing ++ others)

    describe (Obligation _ _ member subject tipe _) =
      do  subjectType <- Type.toErrorType subject
          neededType <- Type.toErrorType tipe
          let var = case subjectType of
                ET.FlexVar n -> TV.varToChars n
                ET.FlexSuper _ n -> TV.varToChars n
                _ -> "a"
          return (var, (member, neededType))

    group items =
      foldl (\acc (var, entry) -> case lookup var acc of
                Just _ -> [ if v == var then (v, es ++ [entry]) else (v, es) | (v, es) <- acc ]
                Nothing -> acc ++ [(var, [entry])]) [] items

    unknown (Obligation region function member subject tipe _) =
      do  (Descriptor content _ _ _) <- UF.get subject
          t <- Type.toErrorType tipe
          return (Error.UnknownMemberType region function (kindOf content) [(member, t)])

    allM p xs =
      case xs of
        [] -> return True
        x : rest -> p x >>= \b -> if b then allM p rest else return False

    anyM p xs =
      case xs of
        [] -> return False
        x : rest -> p x >>= \b -> if b then return True else anyM p rest


-- give the variables of several types their names (a, b, ...) in one go, so that the names of the types that are
-- then shown in one message do not clash (each conversion alone only avoids the names inside its own type)
nameTogether :: [Variable] -> IO ()
nameTogether vars =
  do  unit <- UF.fresh (Descriptor (Structure Unit1) noRank noMark Nothing)
      together <- foldM (\acc var -> UF.fresh (Descriptor (Structure (Pair1 var acc)) noRank noMark Nothing)) unit vars
      _ <- Type.toErrorType together
      return ()


-- the flexible variables in a type (a budget guards against cyclic types)
flexVariables :: Variable -> IO [Variable]
flexVariables start =
  (reverse . snd) <$> go (2000 :: Int, []) start
  where
    go (fuel, acc) var
      | fuel <= 0 = return (fuel, acc)
      | otherwise =
          do  (Descriptor content _ _ _) <- UF.get var
              case content of
                FlexVar _ -> return (fuel - 1, var : acc)
                FlexSuper _ _ -> return (fuel - 1, var : acc)
                Structure flat -> foldM go (fuel - 1, acc) (children flat)
                Alias _ _ args real -> foldM go (fuel - 1, acc) (real : map snd args)
                _ -> return (fuel - 1, acc)

    children flat =
      case flat of
        App1 _ _ args -> args
        Fun1 a b -> [a, b]
        EmptyRecord1 -> []
        Record1 fields ext -> ext : Map.elems fields
        Unit1 -> []
        Pair1 a b -> [a, b]
        Triple1 a b c -> [a, b, c]


-- | after a generalization: an obligation whose subject was generalized can never be discharged.  Only a
-- rigid subject is left here (the signature does not give the constraint): `hold` reported the flexible ones.
sweep :: [Obligation] -> IO ([Obligation], [Error.Error])
sweep pending =
  foldM check ([], []) (reverse pending)
  where
    check (kept, errors) obligation@(Obligation region function member subject tipe _) =
      do  (Descriptor content rank _ _) <- UF.get subject
          if rank /= noRank
            then return (obligation : kept, errors)
            else
              do  neededType <- Type.toErrorType tipe
                  return $ (,) kept $
                    case content of
                      RigidVar name -> Error.MissingConstraint region function (TV.varToChars name) [(member, neededType)] : errors
                      RigidSuper _ name -> Error.MissingConstraint region function (TV.varToChars name) [(member, neededType)] : errors
                      Error -> errors
                      _ -> Error.UnknownMemberType region function (kindOf content) [(member, neededType)] : errors


-- | at the end of the module
leftovers :: [Obligation] -> IO [Error.Error]
leftovers pending =
  traverse leftover pending
  where
    leftover (Obligation region function member subject tipe _) =
      do  (Descriptor content _ _ _) <- UF.get subject
          t <- Type.toErrorType tipe
          return (Error.UnknownMemberType region function (kindOf content) [(member, t)])


-- the kind of a variable of Elm's own (`number`, `comparable`, ...)
kindOf :: Content -> Maybe String
kindOf content =
  case content of
    FlexSuper super _ ->
      Just $
        case super of
          Number -> "number"
          Comparable -> "comparable"
          Appendable -> "appendable"
          CompAppend -> "compappend"
    _ -> Nothing


-- | one error for one use: the errors of the same kind at the same place are put together (in the order
-- of the constraints; the list of the solver is newest first)
merge :: [Error.Error] -> [Error.Error]
merge errors =
  if any isMemberError errors then foldl add [] errors else errors
  where
    isMemberError err =
      case err of
        Error.NoMember {} -> True
        Error.MissingConstraint {} -> True
        Error.UnknownMemberType {} -> True
        _ -> False

    add acc err =
      case err of
        Error.NoMember r f t ms b needed | Just rest <- pick (\e -> case e of { Error.NoMember r2 _ _ _ _ n | r2 == r -> Just n; _ -> Nothing }) acc ->
          place (Error.NoMember r f t ms b (fst rest ++ needed)) (snd rest)
        Error.MissingConstraint r f v needed | Just rest <- pick (\e -> case e of { Error.MissingConstraint r2 _ v2 n | r2 == r && v2 == v -> Just n; _ -> Nothing }) acc ->
          place (Error.MissingConstraint r f v (fst rest ++ needed)) (snd rest)
        Error.UnknownMemberType r f k needed | Just rest <- pick (\e -> case e of { Error.UnknownMemberType r2 _ _ n | r2 == r -> Just n; _ -> Nothing }) acc ->
          place (Error.UnknownMemberType r f k (fst rest ++ needed)) (snd rest)
        _ ->
          acc ++ [err]

    -- the first earlier error that matches (its members), and the list with that error marked by Nothing
    pick match acc =
      case break (\e -> maybe False (const True) (match e)) acc of
        (before, e : after) | Just n <- match e -> Just (n, (before, after))
        _ -> Nothing

    place err (before, after) =
      before ++ [err] ++ after
