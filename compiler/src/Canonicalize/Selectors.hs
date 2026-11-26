{-# LANGUAGE PatternGuards #-}
-- Ficcus (A5b, docs/A5-INFERENCE-DESIGN.md section 2, D5): the selectors of a module.
--
-- A selector is a bare name `m` of an attached function (AST.Selectors).  The *candidate types* are the custom types
-- with a `where` block that the module defines (its top level values `T$$m`) or that it imports in any form (the
-- members an import entered under the keys `T$` and `Prefix.T$`, Canonicalize.Environment.Foreign; opaque types
-- included).  Members of types that only travel inside an interface (`pkg:Module.T$$m`) are not candidates.
--
-- For each member name of the candidates the selector's type is
--   * for a well known name (AST.WellKnown, `add`, `fromInt`, ...) its shape: `add : a -> a -> a`;
--   * for any other name the anti-unification of the candidates' member types, each with its own type (with its
--     arguments) replaced by the subject `a`: `Money.zero : Money` and `Vec.zero : Vec` give `zero : a`;
--     `T.f : T -> Int` and `W.f : W -> T` give `f : a -> b`.  When a position that holds the subject in one candidate
--     holds something else in another (`scale : Money -> Int -> Money` and `scale : Float -> Vec -> Vec`), or the
--     subject is nowhere in the result, the name is not a selector.
--
-- `register` enters each selector under the key `m$selector` (AST.Selectors.selectorKey).  Elm's lookup runs first and
-- is unchanged (Canonicalize.Expression.findVar): the key is read only where Elm reports NAMING ERROR.  A module
-- without candidate types (every Elm module) gets the environment it had.
module Canonicalize.Selectors
  ( register
  , dealias
  )
  where


import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Control.Monad.State.Strict (State, evalState, gets, modify')

import qualified AST.Canonical as Can
import qualified AST.Constraints as Constraints
import qualified AST.Members as Members
import qualified AST.Prim.Module as Module
import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeName as T
import qualified AST.Prim.TypeVar as TV
import qualified AST.Selectors as Selectors
import qualified AST.Source as Src
import qualified AST.WellKnown as WK
import qualified Canonicalize.Environment as Env
import qualified Canonicalize.Type as Type
import qualified Elm.ModuleName as ModuleName
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Canonicalize as Error
import qualified Reporting.Result as Result
import qualified String as S



-- CANDIDATES


-- | an attached function of a candidate type: the type (home and name), the member, its type (without the hidden
-- parameters of its own `where` lines)
data Candidate =
  Candidate
    { _owner :: (ModuleName.Canonical, String)
    , _member :: N.Name
    , _type :: Can.Type
    }


-- | the environment with the selectors of the module whose top level values are `values`
register :: Env.Env -> [A.Located Src.Value] -> Env.Env
register env@(Env.Env home vs ts cs bs qvs qts qcs) values =
  case local env values ++ imported qvs of
    [] ->
      env

    candidates ->
      let
        byMember = Map.fromListWith (++) [ (N.toChars (_member c), [c]) | c <- candidates ]
        selectors = Map.mapMaybeWithKey selectorOf byMember
        vs2 = Map.foldrWithKey (\m annotation acc -> Map.insert (Selectors.selectorKey (name m)) (Env.Foreign Selectors.attachedHome annotation) acc) vs selectors
      in
      Env.Env home vs2 ts cs bs qvs qts qcs
  where
    name = N.fromString . S.fromChars


-- the members of the types of this module that have a type annotation (a member without one is an error of its own)
local :: Env.Env -> [A.Located Src.Value] -> [Candidate]
local env@(Env.Env home _ _ _ _ _ _ _) values =
  [ Candidate (home, tipe) member (snd (peel (hiddenCount args) full))
  | A.At _ (Src.Value (A.At _ n) args _ (Just srcType)) <- values
  , Just (tipe, member) <- [Members.split n]
  , ':' `notElem` tipe
  , Right (Can.Forall _ full) <- [snd (Result.run (annotationOf srcType))]
  ]
  where
    annotationOf :: Src.Type -> Result.Result () [()] Error.Error Can.Annotation
    annotationOf srcType = Type.toAnnotation env srcType


-- the members that the imports entered under a type's key (`T$`, `Prefix.T$`), once per type
imported :: Env.Qualified N.Name Can.Annotation -> [Candidate]
imported qvs =
  Map.elems $ Map.fromList
    [ ((home, tipe, N.toChars member), Candidate (home, tipe) member (maybe t fst (Constraints.unwrap t)))
    | (prefix, qualified) <- Map.toList qvs
    , isTypeKey (Module.prefixToChars prefix)
    , (k, Env.Specific home (Can.Forall _ t)) <- Map.toList qualified
    , Just (tipe, member) <- [Members.split k]
    , ':' `notElem` tipe
    ]
  where
    isTypeKey chars = not (null chars) && last chars == '$'


hiddenCount :: [Src.Pattern] -> Int
hiddenCount patterns =
  case patterns of
    A.At _ (Src.PAlias (A.At _ (Src.PVar m)) _) : rest | Just _ <- Constraints.splitMarker m -> 1 + hiddenCount rest
    _ -> 0


peel :: Int -> Can.Type -> ([Can.Type], Can.Type)
peel n tipe =
  case tipe of
    Can.TLambda a result | n > 0 -> let (as, r) = peel (n - 1) result in (a : as, r)
    _ -> ([], tipe)



-- THE SELECTOR OF ONE NAME


selectorOf :: String -> [Candidate] -> Maybe Can.Annotation
selectorOf member candidates =
  case WK.shapeOf member of
    Just shape ->
      case WK.shapeAnnotation shape of
        Can.Forall _ (Can.TPair (Can.TVar x) body) -> Just (Selectors.scheme name x body)
        _ -> Nothing

    Nothing ->
      do  tipe <- antiUnify (List.sortOn _owner candidates)
          Just (Selectors.scheme name subjectVar tipe)
  where
    name = N.fromString (S.fromChars member)



-- ANTI-UNIFICATION
--
-- Each candidate's type, without aliases, its own type replaced by the subject, and its variables renamed apart (the
-- index of the candidate).  Where all candidates agree the result has their common structure; each tuple of parts
-- that disagree becomes one variable (the same tuple twice: the same variable).


data U
  = USubject
  | UVar Int String
  | UFun U U
  | UCon ModuleName.Canonical String [U]
  | URecord [(String, U)] (Maybe U)
  | UUnit
  | UPair U U
  | UTriple U U U
  deriving (Eq, Ord)


toU :: (Int, Candidate) -> U
toU (i, Candidate (home, tipe) _ t0) =
  go (dealias t0)
  where
    self = firstOwner (dealias t0)

    go t =
      case t of
        Can.TType h n args
          | h == home && T.nameToChars n == tipe && Just args == self -> USubject
          | otherwise -> UCon h (T.nameToChars n) (map go args)
        Can.TLambda a b -> UFun (go a) (go b)
        Can.TVar v -> UVar i (TV.varToChars v)
        Can.TRecord fields ext ->
          URecord [ (N.toChars f, go x) | (f, Can.FieldType _ x) <- Map.toList fields ] (fmap (\v -> UVar i (TV.varToChars v)) ext)
        Can.TUnit -> UUnit
        Can.TPair a b -> UPair (go a) (go b)
        Can.TTriple a b c -> UTriple (go a) (go b) (go c)
        Can.TAlias _ _ _ _ -> go (dealias t)

    -- the arguments of the first occurrence of the type itself, left to right: the occurrences with the same
    -- arguments are the subject (`T x` in `T.map : (x -> y) -> T x -> T y`)
    firstOwner t =
      case t of
        Can.TType h n args
          | h == home && T.nameToChars n == tipe -> Just args
          | otherwise -> firstOf (map firstOwner args)
        Can.TLambda a b -> firstOf [firstOwner a, firstOwner b]
        Can.TRecord fields _ -> firstOf [ firstOwner x | Can.FieldType _ x <- Map.elems fields ]
        Can.TPair a b -> firstOf [firstOwner a, firstOwner b]
        Can.TTriple a b c -> firstOf [firstOwner a, firstOwner b, firstOwner c]
        _ -> Nothing

    firstOf xs =
      case [ x | Just x <- xs ] of
        x : _ -> Just x
        [] -> Nothing


-- `toU` numbers the candidates
toUs :: [Candidate] -> [U]
toUs = map toU . zip [0 ..]


dealias :: Can.Type -> Can.Type
dealias t =
  case t of
    Can.TAlias _ _ args aliasType ->
      case aliasType of
        Can.Filled real -> dealias real
        Can.Holey real -> dealias (substitute (Map.fromList [ (TV.varToChars v, x) | (v, x) <- args ]) real)
    Can.TLambda a b -> Can.TLambda (dealias a) (dealias b)
    Can.TType h n args -> Can.TType h n (map dealias args)
    Can.TRecord fields ext -> Can.TRecord (Map.map (\(Can.FieldType i x) -> Can.FieldType i (dealias x)) fields) ext
    Can.TPair a b -> Can.TPair (dealias a) (dealias b)
    Can.TTriple a b c -> Can.TTriple (dealias a) (dealias b) (dealias c)
    _ -> t


substitute :: Map.Map String Can.Type -> Can.Type -> Can.Type
substitute s t =
  case t of
    Can.TVar v -> Map.findWithDefault t (TV.varToChars v) s
    Can.TLambda a b -> Can.TLambda (go a) (go b)
    Can.TType h n args -> Can.TType h n (map go args)
    Can.TRecord fields ext -> Can.TRecord (Map.map (\(Can.FieldType i x) -> Can.FieldType i (go x)) fields) ext
    Can.TUnit -> t
    Can.TPair a b -> Can.TPair (go a) (go b)
    Can.TTriple a b c -> Can.TTriple (go a) (go b) (go c)
    Can.TAlias h n args real -> Can.TAlias h n [ (v, go x) | (v, x) <- args ] real
  where
    go = substitute s


subjectVar :: TV.Var
subjectVar =
  TV.varFromString (S.fromChars "a")


-- | the common type of the candidates; Nothing: the subject does not survive
antiUnify :: [Candidate] -> Maybe Can.Type
antiUnify candidates =
  case evalState (au (toUs candidates)) (Map.empty, 0) of
    Just t | hasSubject t -> Just t
    _ -> Nothing
  where
    hasSubject t =
      case t of
        Can.TVar v -> v == subjectVar
        Can.TLambda a b -> hasSubject a || hasSubject b
        Can.TType _ _ args -> any hasSubject args
        Can.TRecord fields _ -> any (\(Can.FieldType _ x) -> hasSubject x) (Map.elems fields)
        Can.TPair a b -> hasSubject a || hasSubject b
        Can.TTriple a b c -> hasSubject a || hasSubject b || hasSubject c
        _ -> False


type AU a = State (Map.Map [U] TV.Var, Int) a


au :: [U] -> AU (Maybe Can.Type)
au us =
  case us of
    USubject : _ | all (== USubject) us ->
      return (Just (Can.TVar subjectVar))

    UFun _ _ : _ | Just (as, bs) <- unzip <$> traverse fun us ->
      do  a <- au as
          b <- au bs
          return (Can.TLambda <$> a <*> b)

    UCon h n args : _ | Just argss <- traverse (con h n (length args)) us ->
      do  ts <- mapM au (List.transpose argss)
          return (Can.TType h (T.nameFromString (S.fromChars n)) <$> sequence ts)

    URecord fields ext : _ | Just rows <- traverse (record (map fst fields) (fmap (const ()) ext)) us ->
      do  ts <- mapM au (List.transpose [ map snd fs | (fs, _) <- rows ])
          e <- case [ x | (_, Just x) <- rows ] of
                 [] -> return (Just Nothing)
                 xs -> fmap (fmap (\t -> case t of { Can.TVar v -> Just v ; _ -> Nothing })) (au xs)
          return $
            case (sequence ts, e) of
              (Just ts', Just ext') -> Just (Can.TRecord (Map.fromList [ (N.fromString (S.fromChars f), Can.FieldType 0 t) | (f, t) <- zip (map fst fields) ts' ]) ext')
              _ -> Nothing

    UUnit : _ | all (== UUnit) us ->
      return (Just Can.TUnit)

    UPair _ _ : _ | Just (as, bs) <- unzip <$> traverse pair us ->
      do  a <- au as
          b <- au bs
          return (Can.TPair <$> a <*> b)

    UTriple _ _ _ : _ | Just abcs <- traverse triple us ->
      do  a <- au [ x | (x, _, _) <- abcs ]
          b <- au [ y | (_, y, _) <- abcs ]
          c <- au [ z | (_, _, z) <- abcs ]
          return (Can.TTriple <$> a <*> b <*> c)

    _ | any holdsSubject us ->
      return Nothing

    _ ->
      do  known <- gets (Map.lookup us . fst)
          case known of
            Just v -> return (Just (Can.TVar v))
            Nothing ->
              do  n <- gets snd
                  let v = freshVar (kindOf us) n
                  modify' (\(m, k) -> (Map.insert us v m, k + 1))
                  return (Just (Can.TVar v))
  where
    fun u = case u of { UFun a b -> Just (a, b) ; _ -> Nothing }
    pair u = case u of { UPair a b -> Just (a, b) ; _ -> Nothing }
    triple u = case u of { UTriple a b c -> Just (a, b, c) ; _ -> Nothing }
    con h n k u = case u of { UCon h' n' args | h' == h && n' == n && length args == k -> Just args ; _ -> Nothing }
    record names ext u =
      case u of
        URecord fs e | map fst fs == names && fmap (const ()) e == ext -> Just (fs, e)
        _ -> Nothing


holdsSubject :: U -> Bool
holdsSubject u =
  case u of
    USubject -> True
    UVar _ _ -> False
    UFun a b -> holdsSubject a || holdsSubject b
    UCon _ _ args -> any holdsSubject args
    URecord fields ext -> any (holdsSubject . snd) fields || maybe False holdsSubject ext
    UUnit -> False
    UPair a b -> holdsSubject a || holdsSubject b
    UTriple a b c -> any holdsSubject [a, b, c]


-- a variable for a tuple of variables that all have one of Elm's kinds keeps the kind
kindOf :: [U] -> String
kindOf us =
  case [ kind n | UVar _ n <- us ] of
    ks@(k : _) | length ks == length us && all (== k) ks -> k
    _ -> ""
  where
    kind n =
      case [ k | k <- ["comparable", "appendable", "compappend", "number"], k `List.isPrefixOf` n ] of
        k : _ -> k
        [] -> ""


freshVar :: String -> Int -> TV.Var
freshVar kind n =
  TV.varFromString . S.fromChars $
    case kind of
      "" -> if n < 25 then [toEnum (fromEnum 'b' + n)] else "b" ++ show n
      _ -> kind ++ show (n + 1)
