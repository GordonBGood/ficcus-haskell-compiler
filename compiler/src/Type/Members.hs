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
  , wrapAnnotations
  , Obligation
  , Tools(..)
  , use
  , discharge
  , sweep
  , leftovers
  , merge
  )
  where


import Control.Monad (foldM)
import qualified Data.Map.Strict as Map

import qualified AST.Canonical as Can
import qualified AST.Constraints as Constraints
import qualified AST.Members as Members
import qualified AST.Prim.Module as Module
import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeName as T
import qualified AST.Prim.TypeVar as TV
import qualified Elm.Interface as I
import qualified Elm.ModuleName as ModuleName
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Type as Error
import qualified String as S
import Type.Type as Type
import qualified Type.Unify as Unify
import qualified Type.UnionFind as UF



-- THE MEMBER TABLE


-- | the members a module can see, by type; Nothing: a member of this module without a signature
type Table =
  Map.Map (ModuleName.Canonical, T.Name) (Map.Map N.Name (Maybe Can.Annotation))


emptyTable :: Table
emptyTable =
  Map.empty


-- | from the interfaces of the imports (the values `T$$m`, there when `T` is exported with `(..)`) and
-- the definitions of the module itself
toTable :: Map.Map Module.Name I.Interface -> Can.Module -> Table
toTable ifaces (Can.Module home _ _ decls _ _ _ _) =
  let
    foreign =
      [ ((ModuleName.Canonical (I._home iface) name, tname tipe), Map.singleton member (Just annotation))
      | (name, iface) <- Map.toList ifaces
      , (value, annotation) <- Map.toList (I._values iface)
      , Just (tipe, member) <- [Members.split value]
      ]

    local =
      [ ((home, tname tipe), Map.singleton member (annotationOf def))
      | def <- defsOf decls
      , Just (tipe, member) <- [Members.split (nameOf def)]
      ]
  in
  Map.fromListWith Map.union (local ++ foreign)
  where
    tname = T.nameFromString . S.fromChars

    annotationOf def =
      case def of
        Can.Def _ _ _ -> Nothing
        Can.TypedDef _ freeVars args _ result ->
          Just (Constraints.wrapDef def (Can.Forall freeVars (foldr (\(_, t) acc -> Can.TLambda t acc) result args)))



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



-- OBLIGATIONS


data Obligation =
  Obligation
    { _region :: A.Region
    , _function :: N.Name     -- the constrained function that was used
    , _member :: N.Name
    , _subject :: Variable
    , _type :: Variable
    }


-- | what the solver lends: instantiate an annotation at the current rank, register the variables that a
-- unification made
data Tools =
  Tools
    { _instantiate :: Can.Annotation -> IO Variable
    , _introduce :: [Variable] -> IO ()
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
              return [Obligation region function member subject tipe]

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
resolve tools table env obligation@(Obligation region function member subject tipe) =
  go subject
  where
    go var =
      do  (Descriptor content _ _ _) <- UF.get var
          case content of
            Structure (App1 home name _) ->
              case Map.lookup (home, name) table of
                Just members | Just entry <- Map.lookup member members ->
                  case entry of
                    Just annotation ->
                      do  instance_ <- _instantiate tools annotation
                          (real, more) <- use region function instance_
                          unify (Error.MemberOfType (T.nameToChars name)) real more

                    Nothing ->
                      return (Done [] [Error.MemberNeedsSignature region function member (T.nameToChars name)])

                maybeMembers ->
                  noMember (maybe [] Map.keys maybeMembers)

            Structure _ ->
              noMember []

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

    unify owner actual more =
      do  answer <- Unify.unify actual tipe
          case answer of
            Unify.Ok vars ->
              do  _introduce tools vars
                  return (Done more [])

            Unify.Err vars actualType neededType ->
              do  _introduce tools vars
                  return (Done [] [Error.BadMember region function member owner actualType neededType])

            Unify.Runaway isCycle ->
              return (Done [] [Error.Runaway region isCycle])

    noMember members =
      do  subjectType <- Type.toErrorType subject
          neededType <- Type.toErrorType tipe
          return (Done [] [Error.NoMember region function subjectType members [(member, neededType)]])
      where _ = obligation


-- | after a generalization: an obligation whose subject was generalized cannot be discharged any more.
-- An obligation that stays pending (its subject belongs to an outer definition) keeps its member type at the
-- level of the subject: the variables of the member type that were just generalized are made variables of
-- that level again (returned with their rank, for the pools).  Otherwise a `let` value whose type comes from
-- the member (`let y = get t in ...`, `t` not yet known) would be polymorphic before the member says what it is.
sweep :: [Obligation] -> IO ([Obligation], [Error.Error], [(Int, [Variable])])
sweep pending =
  foldM check ([], [], []) (reverse pending)
  where
    check (kept, errors, pinned) obligation@(Obligation region function member subject tipe) =
      do  (Descriptor content rank _ _) <- UF.get subject
          if rank /= noRank
            then
              do  vars <- pin rank tipe
                  return (obligation : kept, errors, if null vars then pinned else (rank, vars) : pinned)
            else
              do  neededType <- Type.toErrorType tipe
                  return $ (\errs -> (kept, errs, pinned)) $
                    case content of
                      RigidVar name -> Error.MissingConstraint region function (TV.varToChars name) [(member, neededType)] : errors
                      RigidSuper _ name -> Error.MissingConstraint region function (TV.varToChars name) [(member, neededType)] : errors
                      Error -> errors
                      _ -> Error.UnknownMemberType region function [(member, neededType)] : errors


-- the generalized flexible variables in a type get the rank `rank`; a budget guards against cyclic types
pin :: Int -> Variable -> IO [Variable]
pin rank start =
  snd <$> go (2000 :: Int, []) start
  where
    go (fuel, acc) var
      | fuel <= 0 = return (fuel, acc)
      | otherwise =
          do  (Descriptor content r mark copy) <- UF.get var
              case content of
                FlexVar _ | r == noRank -> UF.set var (Descriptor content rank mark copy) >> return (fuel - 1, var : acc)
                FlexSuper _ _ | r == noRank -> UF.set var (Descriptor content rank mark copy) >> return (fuel - 1, var : acc)
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


-- | at the end of the module
leftovers :: [Obligation] -> IO [Error.Error]
leftovers pending =
  traverse (\(Obligation region function member _ tipe) -> (\t -> Error.UnknownMemberType region function [(member, t)]) <$> Type.toErrorType tipe) pending


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
        Error.NoMember r f t ms needed | Just rest <- pick (\e -> case e of { Error.NoMember r2 _ _ _ n | r2 == r -> Just n; _ -> Nothing }) acc ->
          place (Error.NoMember r f t ms (fst rest ++ needed)) (snd rest)
        Error.MissingConstraint r f v needed | Just rest <- pick (\e -> case e of { Error.MissingConstraint r2 _ v2 n | r2 == r && v2 == v -> Just n; _ -> Nothing }) acc ->
          place (Error.MissingConstraint r f v (fst rest ++ needed)) (snd rest)
        Error.UnknownMemberType r f needed | Just rest <- pick (\e -> case e of { Error.UnknownMemberType r2 _ n | r2 == r -> Just n; _ -> Nothing }) acc ->
          place (Error.UnknownMemberType r f (fst rest ++ needed)) (snd rest)
        _ ->
          acc ++ [err]

    -- the first earlier error that matches (its members), and the list with that error marked by Nothing
    pick match acc =
      case break (\e -> maybe False (const True) (match e)) acc of
        (before, e : after) | Just n <- match e -> Just (n, (before, after))
        _ -> Nothing

    place err (before, after) =
      before ++ [err] ++ after
