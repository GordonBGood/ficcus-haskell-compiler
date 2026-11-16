{-# OPTIONS_GHC -Wall #-}
module Ficcus.Mono.Members
  ( exactRoots
  , peel
  , subjectNames
  , matchM
  , fullCanType
  )
  where


-- Ficcus (ATTACH, stage A2): helpers of the specializer for constrained definitions (AST.Constraints,
-- docs/attach/A2-DESIGN.md section 4).
--
-- A constrained definition has hidden leading parameters, one per required member.  A clone of it does
-- not take them: the variables of its constraints are keyed by their exact type (`exactRoots`: extra
-- roots of the marks fixpoint), and from that type the member function is found (`Type$$member` in the
-- module of the type) and a clone of it requested for the member type (`matchM`).


import qualified Data.Map.Strict as Map

import qualified AST.Canonical as Can
import qualified AST.Constraints as Constraints
import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeName as T
import Ficcus.Mono.Class (MType(..))
import Ficcus.Mono.Modules (ModuleData(..))
import Type.Dump (Ctx(..), canonVars, defIdOf, defKeyOf, moduleChars)
import Type.Readout


-- | the first n parameter types of a function type, and the rest
peel :: Int -> TType -> ([TType], TType)
peel n t
  | n <= 0 = ([], t)
  | otherwise =
      case t of
        TFun a b -> let (as, r) = peel (n - 1) b in (a : as, r)
        TAlias _ _ _ real -> peel n real
        _ -> ([], t)


-- | the type of a typed definition as it is written, with its hidden parameters
fullCanType :: Can.Def -> Maybe Can.Type
fullCanType def =
  case def of
    Can.Def _ _ _ -> Nothing
    Can.TypedDef _ _ args _ result -> Just (foldr (\(_, t) acc -> Can.TLambda t acc) result args)


-- | for each hidden parameter of a definition, the name that the variable of its constraint has in the
-- recorded scheme (the variables of the written type and of the scheme are numbered alike)
subjectNames :: Can.Def -> TType -> [Maybe String]
subjectNames def scheme =
  case fullCanType def of
    Nothing -> []
    Just full ->
      let
        written = canonVars (canToTType full)
        recorded = Map.fromList [ (i, n) | (n, i) <- canonVars scheme ]
      in
      [ lookup var written >>= \i -> Map.lookup i recorded | Constraints.Hidden var _ _ <- Constraints.hiddenOfDef def ]


-- | the variables (definition id, index) of the constraints of the constrained definitions: keyed by exact type
exactRoots :: [ModuleData] -> [(String, Int)]
exactRoots modules =
  [ (defIdOf (mmCtx m) (defKeyOf d), i)
  | m <- modules
  , d <- mmDefs m
  , let k = Constraints.hiddenCount d
  , k > 0
  , Just scheme <- [Map.lookup (defKeyOf d) (_defs (_typed (mmCtx m)))]
  , let names = concatMap (map fst . canonVars) (fst (peel k scheme))
  , (n, i) <- canonVars scheme
  , n `elem` names
  ]


-- | bind the variables of a scheme to the parts of an exact type
matchM :: TType -> MType -> Either String (Map.Map String MType)
matchM scheme inst =
  go Map.empty scheme inst
  where
    go s a b =
      case (a, b) of
        (TAlias _ _ _ real, _) -> go s real b
        (TVar n _ _, _) ->
          case Map.lookup n s of
            Nothing -> Right (Map.insert n b s)
            Just old | old == b -> Right s
            Just _ -> Left ("the variable " ++ n ++ " is bound to two types")
        (TCon h n args, TyCon name args') | moduleChars h ++ "." ++ N.toChars (T.nameToName n) == name && length args == length args' -> goAll s (zip args args')
        (TFun x y, TyFun x' y') -> go s x x' >>= \s1 -> go s1 y y'
        (TUnit, TyUnit) -> Right s
        (TPair x y, TyTuple [x', y']) -> goAll s [(x, x'), (y, y')]
        (TTriple x y z, TyTuple [x', y', z']) -> goAll s [(x, x'), (y, y'), (z, z')]
        (TRecord fields Nothing, TyRecord fields') | Map.size fields == length fields' ->
          goAll s [ (t, t') | (k, t) <- Map.toList fields, Just t' <- [lookup (N.toChars k) fields'] ]
        (TRef _, _) -> Right s
        _ -> Left "the member has another shape than the constraint"

    goAll s pairs =
      case pairs of
        [] -> Right s
        (x, y) : rest -> go s x y >>= \s1 -> goAll s1 rest
