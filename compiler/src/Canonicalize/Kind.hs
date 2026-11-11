-- The kind check of record extensions (Ficcus track D10).
--
-- Elm checks only the number of type arguments. A type like `{ a | x : Int }` needs `a` to be
-- a record, but nothing checked that: `type alias A a = { a | x : () }` used as `A ()` or `A Int`
-- made the solver die with an internal error, and `A { x : String }` was accepted although the
-- record would have `x` twice (the outermost one won). Here a type variable has one of two kinds:
--
--   KType         an ordinary type
--   KRow fields   the extension of a record that already has `fields` (it may also be used as an
--                 ordinary type: a record is a type, as in `type alias X2 t = { t | x : t }`, case 2029)
--
-- The kind of the parameters of a type alias is found from its body (and cached, so that a chain of
-- nested aliases is visited once); an argument in a row position must expand to a record (or to a
-- type variable, which is checked where it is bound) and must not repeat a field.
module Canonicalize.Kind
  ( checkTypes
  )
  where


import Control.Monad (forM_, when)
import Control.Monad.State.Strict (State, evalState, gets, modify')
import qualified Data.Map as Map

import qualified AST.Canonical as Can
import qualified AST.Utils.Row as Row
import qualified AST.Utils.Type as Type
import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeName as T
import qualified AST.Prim.TypeVar as T
import qualified Elm.ModuleName as ModuleName
import qualified Reporting.Error.Kind as Kind



-- KINDS


data Kind
  = KType
  | KRow (Map.Map N.Name Can.Type)


-- A type argument together with the arguments of the aliases it is inside of
data Arg = Arg Env Can.Type

type Env = Map.Map T.Var Arg

type Via = Maybe (T.Name, T.Var)

data State_ =
  State_
    { _cache :: Map.Map (ModuleName.Canonical, T.Name) (Map.Map T.Var Kind)
    , _kinds :: Map.Map T.Var Kind
    , _problems :: [Kind.Problem]   -- newest first
    }

type M = State State_



-- CHECK


-- | The first problem found in the types of one declaration (they share their type variables).
checkTypes :: [Can.Type] -> Maybe Kind.Problem
checkTypes types =
  let
    run =
      do  forM_ types (walkType Map.empty)
          gets (\s -> case _problems s of [] -> Nothing ; ps -> Just (last ps))
  in
  evalState run (State_ Map.empty Map.empty [])


-- WALK


problem :: Kind.Problem -> M ()
problem p =
  modify' (\s -> s { _problems = p : _problems s })


useVar :: T.Var -> Kind -> M ()
useVar var kind =
  do  kinds <- gets _kinds
      case Map.lookup var kinds of
        Nothing ->
          modify' (\s -> s { _kinds = Map.insert var kind kinds })

        Just old ->
          case (old, kind) of
            (KType, KType) -> return ()
            (KRow a, KRow b) -> modify' (\s -> s { _kinds = Map.insert var (KRow (Map.union a b)) kinds })
            (KRow _, KType) -> return ()
            (KType, KRow _) -> modify' (\s -> s { _kinds = Map.insert var kind kinds })


-- a type in an ordinary position
walkType :: Env -> Can.Type -> M ()
walkType env tipe =
  case tipe of
    Can.TVar v ->
      case Map.lookup v env of
        Just (Arg env' t) -> walkType env' t
        Nothing -> useVar v KType

    Can.TLambda a b -> walkType env a >> walkType env b
    Can.TType _ _ args -> mapM_ (walkType env) args
    Can.TUnit -> return ()
    Can.TPair a b -> walkType env a >> walkType env b
    Can.TTriple a b c -> walkType env a >> walkType env b >> walkType env c

    Can.TRecord fields maybeExt ->
      do  forM_ fields (walkField env)
          forM_ maybeExt $ \ext ->
            walkRow Nothing (resolveFields env fields) env (Can.TVar ext)

    Can.TAlias home name args (Can.Holey body) ->
      do  kinds <- paramKinds home name body
          let aliasEnv = Map.fromList [ (p, Arg env a) | (p, a) <- args ]
          forM_ args $ \(param@(T.Var _ constraint), arg) ->
            do  let given = Type.iteratedDealias (resolve env arg)
                when (not (satisfies constraint given)) $
                  problem (Kind.UnmetConstraint name param given)
          forM_ args $ \(param, arg) ->
            case Map.lookup param kinds of
              Just (KRow fields) -> walkRow (Just (name, param)) (Map.map (resolve aliasEnv) fields) env arg
              _ -> walkType env arg

    Can.TAlias _ _ _ (Can.Filled body) ->
      walkType env body


walkField :: Env -> Can.FieldType -> M ()
walkField env (Can.FieldType _ tipe) =
  walkType env tipe


-- a type that is the extension of a record that has the fields `above` (with their types; a field that is
-- given again is accepted when the two types can be one type, as in Elm 0.19, which the packages that
-- mark a record with a phantom field rely on; the types are then merged, see `Row.mergeField`)
walkRow :: Via -> Map.Map N.Name Can.Type -> Env -> Can.Type -> M ()
walkRow via above env tipe =
  case tipe of
    Can.TVar v ->
      case Map.lookup v env of
        Just (Arg env' t) -> walkRow via above env' t
        Nothing -> useVar v (KRow above)

    Can.TRecord fields maybeExt ->
      do  let own = resolveFields env fields
          let clashes =
                [ (name, t1, t2)
                | (name, t2) <- Map.toList own
                , Just t1 <- [Map.lookup name above]
                , Nothing <- [Row.mergeField Type.iteratedDealias t1 t2]
                ]
          when (not (null clashes)) $ problem (Kind.DuplicateFields via clashes)
          forM_ fields (walkField env)
          forM_ maybeExt $ \ext ->
            walkRow via (Map.unionWith (\a b -> maybe a id (Row.mergeField Type.iteratedDealias a b)) above own) env (Can.TVar ext)

    Can.TAlias _ _ args (Can.Holey body) ->
      -- the expansion of the alias: its parameters are bound to its arguments
      walkRow via above (Map.fromList [ (p, Arg env a) | (p, a) <- args ]) body

    Can.TAlias _ _ _ (Can.Filled body) ->
      walkRow via above env body

    _ ->
      problem (Kind.NotARecord via tipe)


-- | Can a type be the value of a constrained type variable? (Only a type that certainly cannot says no:
-- a type variable says yes, as Elm 0.19 accepts programs that give an alias parameter named `comparable` a
-- plain type variable.)
satisfies :: T.Constraint -> Can.Type -> Bool
satisfies constraint tipe =
  case tipe of
    Can.TVar _ -> True
    Can.TAlias {} -> satisfies constraint (Type.iteratedDealias tipe)
    _ ->
      case constraint of
        T.Any -> True
        T.Number -> isNamed ["Int", "Float"]
        T.Comparable -> comparable tipe
        T.Appendable -> isNamed ["String"] || isList
        T.CompAppend -> isNamed ["String"] || (isList && all (satisfies T.Comparable) listArgs)
  where
    isNamed names = case tipe of Can.TType _ n [] -> T.nameToChars n `elem` names ; _ -> False
    isList = case tipe of Can.TType _ n [_] -> T.nameToChars n == "List" ; _ -> False
    listArgs = case tipe of Can.TType _ _ args -> args ; _ -> []
    comparable t =
      case Type.iteratedDealias t of
        Can.TVar _ -> True
        Can.TType _ n [] -> T.nameToChars n `elem` ["Int", "Float", "Char", "String"]
        Can.TType _ n [a] -> T.nameToChars n == "List" && comparable a
        Can.TPair a b -> comparable a && comparable b
        Can.TTriple a b c -> comparable a && comparable b && comparable c
        _ -> False


resolveFields :: Env -> Map.Map N.Name Can.FieldType -> Map.Map N.Name Can.Type
resolveFields env fields =
  Map.map (\(Can.FieldType _ t) -> resolve env t) fields


-- the type with the type variables that are bound by the arguments replaced
resolve :: Env -> Can.Type -> Can.Type
resolve env tipe =
  case tipe of
    Can.TVar v ->
      case Map.lookup v env of
        Just (Arg env' t) -> resolve env' t
        Nothing -> tipe

    Can.TLambda a b -> Can.TLambda (resolve env a) (resolve env b)
    Can.TType h n args -> Can.TType h n (map (resolve env) args)
    Can.TUnit -> tipe
    Can.TPair a b -> Can.TPair (resolve env a) (resolve env b)
    Can.TTriple a b c -> Can.TTriple (resolve env a) (resolve env b) (resolve env c)
    Can.TRecord fields ext ->
      Can.TRecord (Map.map (\(Can.FieldType i t) -> Can.FieldType i (resolve env t)) fields) ext
    Can.TAlias h n args body ->
      Can.TAlias h n [ (p, resolve env a) | (p, a) <- args ] body


-- the kinds of the parameters of an alias, from its body
paramKinds :: ModuleName.Canonical -> T.Name -> Can.Type -> M (Map.Map T.Var Kind)
paramKinds home name body =
  do  cache <- gets _cache
      case Map.lookup (home, name) cache of
        Just kinds -> return kinds
        Nothing ->
          do  saved <- gets (\s -> (_kinds s, _problems s))
              modify' (\s -> s { _kinds = Map.empty })
              walkType Map.empty body
              kinds <- gets _kinds
              modify' (\s -> s { _kinds = fst saved, _problems = snd saved
                               , _cache = Map.insert (home, name) kinds (_cache s) })
              return kinds
