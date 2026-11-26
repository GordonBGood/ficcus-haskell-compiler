{-# LANGUAGE PatternGuards #-}
-- Ficcus (ATTACH, stage A2): constraints of signatures in the canonicalizer.
--
-- The parser made every constrained definition a definition with hidden leading parameters
-- (AST.Constraints).  This module
--   * checks the rules for the names of the constraints (no shadowing, `as`), and
--   * enters the constrained scheme of each such definition in the environment, under a key that cannot
--     be written (`sum$where`), so that a use of the definition in its own module becomes the same node
--     as a use of an imported one: `Can.VarForeign home name scheme`.
module Canonicalize.Constraints
  ( register
  , localVar
  )
  where


import Control.Monad (foldM)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import qualified AST.Canonical as Can
import qualified AST.Constraints as Constraints
import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeVar as T
import qualified AST.Source as Src
import qualified Canonicalize.Environment as Env
import qualified Canonicalize.Members as Members
import qualified Canonicalize.Type as Type
import qualified Elm.ModuleName as ModuleName
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Canonicalize as Error
import qualified Reporting.Result as Result


type Result i w a =
  Result.Result i w Error.Error a


data Hidden =
  Hidden
    { _region :: A.Region
    , _var :: String
    , _member :: N.Name
    , _local :: A.Located N.Name
    }


-- the hidden parameters of a source definition
hiddenOf :: [Src.Pattern] -> [Hidden]
hiddenOf patterns =
  case patterns of
    A.At region (Src.PAlias (A.At _ (Src.PVar m)) local) : rest | Just (var, member) <- Constraints.splitMarker m ->
      Hidden region var member local : hiddenOf rest
    _ ->
      []


-- | the environment with the constrained schemes of the top level definitions
register :: Env.Env -> [A.Located Src.Value] -> Result i w Env.Env
register env values =
  foldM add env values
  where
    add acc (A.At _ (Src.Value (A.At _ name) args _ maybeType)) =
      case (hiddenOf args, maybeType) of
        (hidden@(_ : _), Just srcType) ->
          do  checkNames (Members.memberEnv name env) hidden
              annotation@(Can.Forall _ full) <- Type.toAnnotation env srcType
              let Can.Forall freeVars wrapped = Constraints.wrap [ Constraints.Hidden v m l | Hidden _ v m (A.At _ l) <- hidden ] annotation
              checkVars name full hidden
              Result.ok (insert (Constraints.whereKey name) (Can.Forall freeVars wrapped) acc)

        _ ->
          Result.ok acc

    insert key annotation (Env.Env home vs ts cs bs qvs qts qcs) =
      Env.Env home (Map.insert key (Env.Foreign home annotation) vs) ts cs bs qvs qts qcs


-- the names of the constraints: one name once, one `var has member` once, and no name of a top level
-- definition (or of a sibling member)
checkNames :: Env.Env -> [Hidden] -> Result i w ()
checkNames (Env.Env _ vs _ _ _ _ _ _) hidden =
  go Map.empty Map.empty hidden
  where
    go _ _ [] = Result.ok ()
    go locals pairs (Hidden region var member (A.At localRegion local) : rest) =
      case (Map.lookup local locals, Map.lookup (var, member) pairs, Map.lookup local vs) of
        (_, Just first, _) ->
          Result.throw (Error.ConstraintTwice var member first region)

        (Just first, _, _) ->
          Result.throw (Error.ConstraintNameTwice local var member first localRegion)

        (_, _, Just (Env.TopLevel first)) ->
          Result.throw (Error.ConstraintShadows local var member first localRegion)

        _ ->
          go (Map.insert local localRegion locals) (Map.insert (var, member) region pairs) rest


-- every type variable of a constraint (the variable it is about and the variables of the type of the member)
-- must be determined by the type of the function: the constraint is solved from the types at each use.
-- (A5a, D2) A variable of a member type is determined when the subject of that constraint is: the subject's type
-- decides which member it is, and so the member's type (docs/A5-INFERENCE-DESIGN.md section 1, rule 3).
checkVars :: N.Name -> Can.Type -> [Hidden] -> Result i w ()
checkVars name full hidden =
  let
    (memberTypes, real) = peel (length hidden) full
    vars = determined (typeVars real)
    determined det =
      let more = Set.unions [ typeVars t | (Hidden _ var _ _, t) <- zip hidden memberTypes, Set.member var det ]
          det' = Set.union det more
      in if Set.size det' == Set.size det then det else determined det'
    missing =
      [ (region, var, member, v)
      | (Hidden region var member _, memberType) <- zip hidden memberTypes
      , v <- var : Set.toList (typeVars memberType)
      , not (Set.member v vars)
      ]
  in
  case missing of
    (region, var, member, v) : _ ->
      Result.throw (Error.AmbiguousConstraint region var member v name)

    [] ->
      Result.ok ()


peel :: Int -> Can.Type -> ([Can.Type], Can.Type)
peel n tipe =
  case tipe of
    Can.TLambda a result | n > 0 -> let (as, r) = peel (n - 1) result in (a : as, r)
    _ -> ([], tipe)


typeVars :: Can.Type -> Set.Set String
typeVars tipe =
  case tipe of
    Can.TLambda a b -> Set.union (typeVars a) (typeVars b)
    Can.TVar v -> Set.singleton (T.varToChars v)
    Can.TType _ _ args -> Set.unions (map typeVars args)
    Can.TRecord fields ext ->
      Set.unions (maybe Set.empty (Set.singleton . T.varToChars) ext : [ typeVars t | Can.FieldType _ t <- Map.elems fields ])
    Can.TUnit -> Set.empty
    Can.TPair a b -> Set.union (typeVars a) (typeVars b)
    Can.TTriple a b c -> Set.unions [typeVars a, typeVars b, typeVars c]
    Can.TAlias _ _ args _ -> Set.unions (map (typeVars . snd) args)


-- | a use of the top level definition `name` of this module
localVar :: Map.Map N.Name Env.Var -> ModuleName.Canonical -> N.Name -> Can.Expr_
localVar vs home name =
  case Map.lookup (Constraints.whereKey name) vs of
    Just (Env.Foreign h annotation) -> Can.VarForeign h name annotation
    _ -> Can.VarTopLevel home name
