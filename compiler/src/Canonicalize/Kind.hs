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
import qualified Data.Set as Set

import qualified AST.Canonical as Can
import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeName as T
import qualified AST.Prim.TypeVar as T
import qualified Elm.ModuleName as ModuleName
import qualified Reporting.Error.Kind as Kind



-- KINDS


data Kind
  = KType
  | KRow (Set.Set N.Name)


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
            (KRow a, KRow b) -> modify' (\s -> s { _kinds = Map.insert var (KRow (Set.union a b)) kinds })
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
            walkRow Nothing (Map.keysSet fields) env (Can.TVar ext)

    Can.TAlias home name args (Can.Holey body) ->
      do  kinds <- paramKinds home name body
          forM_ args $ \(param, arg) ->
            case Map.lookup param kinds of
              Just (KRow fields) -> walkRow (Just (name, param)) fields env arg
              _ -> walkType env arg

    Can.TAlias _ _ _ (Can.Filled body) ->
      walkType env body


walkField :: Env -> Can.FieldType -> M ()
walkField env (Can.FieldType _ tipe) =
  walkType env tipe


-- a type that is the extension of a record that has the fields `above`
walkRow :: Via -> Set.Set N.Name -> Env -> Can.Type -> M ()
walkRow via above env tipe =
  case tipe of
    Can.TVar v ->
      case Map.lookup v env of
        Just (Arg env' t) -> walkRow via above env' t
        Nothing -> useVar v (KRow above)

    Can.TRecord fields maybeExt ->
      do  let own = Map.keysSet fields
          let repeated = Set.toList (Set.intersection above own)
          when (not (null repeated)) $ problem (Kind.DuplicateFields via repeated)
          forM_ fields (walkField env)
          forM_ maybeExt $ \ext ->
            walkRow via (Set.union above own) env (Can.TVar ext)

    Can.TAlias _ _ args (Can.Holey body) ->
      -- the expansion of the alias: its parameters are bound to its arguments
      walkRow via above (Map.fromList [ (p, Arg env a) | (p, a) <- args ]) body

    Can.TAlias _ _ _ (Can.Filled body) ->
      walkRow via above env body

    _ ->
      problem (Kind.NotARecord via tipe)


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
