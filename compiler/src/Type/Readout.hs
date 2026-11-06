{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE PatternGuards #-}
module Type.Readout
  ( Typed(..)
  , TType(..)
  , Kind(..)
  , readout
  , canToTType
  , strip
  , eqT
  , tvars
  , Subst
  , matchT
  , applyDefault
  , defaultKind
  )
  where


-- Ficcus milestone 2, step 2: from solver variables to immutable types.
--
-- After Type.Solve.run the union-find graph still holds the final type of every
-- node variable that Type.Recorder collected. `readout` first gives every
-- distinct unresolved variable a unique name in place (`a#12`), so that the
-- identity of a type variable is its name, then converts each recorded variable
-- into a TType.
--
-- Variables that are still unresolved are the quantified variables of the
-- enclosing definition, or variables that no definition mentions (dead). The
-- caller decides which is which (see Type.Dump); `applyDefault` implements the
-- defaulting table for the second kind.


import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map

import qualified String as S

import qualified AST.Canonical as Can
import qualified AST.Prim.Module as Module
import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeName as T
import qualified AST.Prim.TypeVar as T
import qualified Elm.ModuleName as ModuleName
import Type.Recorder (Key, DefKey)
import qualified Type.Recorder as Recorder
import Type.Type (Variable, Descriptor(..), Content(..), FlatType(..), SuperType(..))
import qualified Type.UnionFind as UF



-- TYPES


data Kind
  = KAny
  | KNumber
  | KComparable
  | KAppendable
  | KCompAppend
  deriving (Eq, Ord, Show)


data TType
  = TCon ModuleName.Canonical T.Name [TType]
  | TFun TType TType
  | TRecord (Map.Map N.Name TType) (Maybe TType)
  | TUnit
  | TPair TType TType
  | TTriple TType TType TType
  | TVar String Kind Bool            -- unique name, kind, rigid
  | TAlias ModuleName.Canonical T.Name [(String, TType)] TType
  | TRef Kind                        -- reference class: result of defaulting
  | TError


data Typed =
  Typed
    { _nodes :: Map.Map Key TType
    , _defs :: Map.Map DefKey TType
    }



-- READ OUT


readout :: Recorder.Recorder -> IO Typed
readout recorder =
  do  nodeVars <- Recorder.readNodes recorder
      defVars <- Recorder.readDefs recorder
      counter <- newIORef (0 :: Int)
      mapM_ (nameVars counter 0) (Map.elems nodeVars)
      mapM_ (nameVars counter 0) (Map.elems defVars)
      nodes <- traverse (toType 0) nodeVars
      defs <- traverse (toType 0) defVars
      return (Typed nodes defs)



-- NAME EVERY UNRESOLVED VARIABLE


maxDepth :: Int
maxDepth =
  400


nameVars :: IORef Int -> Int -> Variable -> IO ()
nameVars counter depth var =
  if depth > maxDepth then return () else
  do  (Descriptor content rank mark copy) <- UF.get var
      let
        set newContent = UF.set var (Descriptor newContent rank mark copy)
        go = nameVars counter (depth + 1)
      case content of
        FlexVar maybeName ->
          do  name <- fresh KAny maybeName
              mapM_ (\n -> set (FlexVar (Just n))) name

        FlexSuper super maybeName ->
          do  name <- fresh (superToKind super) maybeName
              mapM_ (\n -> set (FlexSuper super (Just n))) name

        RigidVar name ->
          do  newName <- fresh KAny (Just name)
              mapM_ (\n -> set (RigidVar n)) newName

        RigidSuper super name ->
          do  newName <- fresh (superToKind super) (Just name)
              mapM_ (\n -> set (RigidSuper super n)) newName

        Structure flat ->
          case flat of
            App1 _ _ args -> mapM_ go args
            Fun1 a b -> go a >> go b
            EmptyRecord1 -> return ()
            Record1 fields ext -> mapM_ go fields >> go ext
            Unit1 -> return ()
            Pair1 a b -> go a >> go b
            Triple1 a b c -> go a >> go b >> go c

        Alias _ _ args real ->
          mapM_ (go . snd) args >> go real

        Error ->
          return ()
  where
    -- Nothing when the variable already has a unique name
    fresh kind maybeName =
      case maybeName of
        Just name | isUnique name -> return Nothing
        _ ->
          do  n <- readIORef counter
              writeIORef counter (n + 1)
              let base = maybe (kindBase kind) T.varToChars maybeName
              return $ Just $ T.Var (S.fromChars (base ++ "#" ++ show n)) (kindConstraint kind)


isUnique :: T.Var -> Bool
isUnique name =
  '#' `elem` T.varToChars name


kindBase :: Kind -> String
kindBase kind =
  case kind of
    KAny        -> "t"
    KNumber     -> "number"
    KComparable -> "comparable"
    KAppendable -> "appendable"
    KCompAppend -> "compappend"


kindConstraint :: Kind -> T.Constraint
kindConstraint kind =
  case kind of
    KAny        -> T.Any
    KNumber     -> T.Number
    KComparable -> T.Comparable
    KAppendable -> T.Appendable
    KCompAppend -> T.CompAppend


superToKind :: SuperType -> Kind
superToKind super =
  case super of
    Number     -> KNumber
    Comparable -> KComparable
    Appendable -> KAppendable
    CompAppend -> KCompAppend



-- CONVERT


toType :: Int -> Variable -> IO TType
toType depth var =
  if depth > maxDepth then return TError else
  do  (Descriptor content _ _ _) <- UF.get var
      let go = toType (depth + 1)
      case content of
        FlexVar maybeName ->
          return (named KAny False maybeName)

        FlexSuper super maybeName ->
          return (named (superToKind super) False maybeName)

        RigidVar name ->
          return (named KAny True (Just name))

        RigidSuper super name ->
          return (named (superToKind super) True (Just name))

        Structure flat ->
          case flat of
            App1 home name args -> TCon home name <$> traverse go args
            Fun1 a b -> TFun <$> go a <*> go b
            EmptyRecord1 -> return (TRecord Map.empty Nothing)
            Record1 fields ext ->
              do  fs <- traverse go fields
                  e <- go ext
                  return (mkRecord fs (Just e))
            Unit1 -> return TUnit
            Pair1 a b -> TPair <$> go a <*> go b
            Triple1 a b c -> TTriple <$> go a <*> go b <*> go c

        Alias home name args real ->
          do  as <- traverse (\(n, v) -> (,) (T.varToChars n) <$> go v) args
              r <- go real
              return (TAlias home name as r)

        Error ->
          return TError
  where
    named kind rigid maybeName =
      TVar (maybe "?" T.varToChars maybeName) kind rigid


-- merge the extension into the record: a record extension is a variable, the
-- empty record or another record (possibly behind aliases)
mkRecord :: Map.Map N.Name TType -> Maybe TType -> TType
mkRecord fields ext =
  case fmap strip ext of
    Just (TRecord sub subExt) -> TRecord (Map.union fields sub) subExt
    Just (TVar n k r)         -> TRecord fields (Just (TVar n k r))
    Nothing                   -> TRecord fields Nothing
    Just _                    -> TRecord fields (Just TError)


strip :: TType -> TType
strip tipe =
  case tipe of
    TAlias _ _ _ real -> strip real
    _                 -> tipe



-- SOURCE TYPES (annotations of imported names and operators)


canToTType :: Can.Type -> TType
canToTType =
  canToT Map.empty


canToT :: Map.Map String TType -> Can.Type -> TType
canToT params tipe =
  case tipe of
    Can.TLambda a b -> TFun (go a) (go b)
    Can.TVar name -> varFor name
    Can.TType home name args -> TCon home name (map go args)
    Can.TRecord fields ext ->
      mkRecord
        (Map.map (\(Can.FieldType _ t) -> go t) fields)
        (fmap varFor ext)
    Can.TUnit -> TUnit
    Can.TPair a b -> TPair (go a) (go b)
    Can.TTriple a b c -> TTriple (go a) (go b) (go c)
    Can.TAlias home name args aliasType ->
      let
        argTypes = map (\(n, t) -> (T.varToChars n, go t)) args
        real =
          case aliasType of
            Can.Holey body -> canToT (Map.fromList argTypes) body
            Can.Filled body -> go body
      in
      TAlias home name argTypes real
  where
    go = canToT params

    varFor name@(T.Var _ c) =
      case Map.lookup (T.varToChars name) params of
        Just t -> t
        Nothing -> TVar (T.varToChars name) (constraintKind c) False


constraintKind :: T.Constraint -> Kind
constraintKind c =
  case c of
    T.Any        -> KAny
    T.Comparable -> KComparable
    T.Appendable -> KAppendable
    T.CompAppend -> KCompAppend
    T.Number     -> KNumber



-- EQUALITY AND VARIABLES


eqT :: TType -> TType -> Bool
eqT x y =
  case (strip x, strip y) of
    (TCon h1 n1 as, TCon h2 n2 bs) -> h1 == h2 && n1 == n2 && sameLength as bs && and (zipWith eqT as bs)
    (TFun a1 b1, TFun a2 b2) -> eqT a1 a2 && eqT b1 b2
    (TRecord f1 e1, TRecord f2 e2) ->
      Map.keys f1 == Map.keys f2 && and (zipWith eqT (Map.elems f1) (Map.elems f2)) && eqMaybe e1 e2
    (TUnit, TUnit) -> True
    (TPair a1 b1, TPair a2 b2) -> eqT a1 a2 && eqT b1 b2
    (TTriple a1 b1 c1, TTriple a2 b2 c2) -> eqT a1 a2 && eqT b1 b2 && eqT c1 c2
    (TVar n1 _ _, TVar n2 _ _) -> n1 == n2
    (TRef k1, TRef k2) -> k1 == k2
    _ -> False
  where
    sameLength as bs = length as == length bs
    eqMaybe (Just a) (Just b) = eqT a b
    eqMaybe Nothing Nothing = True
    eqMaybe _ _ = False


-- every type variable in a type: unique name and kind
tvars :: TType -> [(String, Kind)]
tvars tipe =
  case tipe of
    TCon _ _ args -> concatMap tvars args
    TFun a b -> tvars a ++ tvars b
    TRecord fields ext -> concatMap tvars (Map.elems fields) ++ maybe [] tvars ext
    TUnit -> []
    TPair a b -> tvars a ++ tvars b
    TTriple a b c -> tvars a ++ tvars b ++ tvars c
    TVar n k _ -> [(n, k)]
    TAlias _ _ _ real -> tvars real
    TRef _ -> []
    TError -> []



-- DEFAULTING


-- table of docs/TYPED-IR-DESIGN.md section 3, as amended by the user:
-- number becomes Int, every other unresolved variable the reference class.
defaultKind :: Kind -> TType
defaultKind kind =
  case kind of
    KNumber -> TCon ModuleName.basics T.int []
    _       -> TRef kind


-- replace the variables for which `dead` holds by their default
applyDefault :: (String -> Bool) -> TType -> TType
applyDefault dead tipe =
  case tipe of
    TCon h n args -> TCon h n (map go args)
    TFun a b -> TFun (go a) (go b)
    TRecord fields ext ->
      case fmap go ext of
        Just (TRef _) -> TRecord (Map.map go fields) Nothing
        newExt        -> TRecord (Map.map go fields) newExt
    TUnit -> TUnit
    TPair a b -> TPair (go a) (go b)
    TTriple a b c -> TTriple (go a) (go b) (go c)
    TVar n k _ | dead n -> defaultKind k
    TVar _ _ _ -> tipe
    TAlias h n args real -> TAlias h n (map (fmap go) args) (go real)
    TRef _ -> tipe
    TError -> tipe
  where
    go = applyDefault dead



-- structure only, for diagnostics
describe :: TType -> String
describe tipe =
  case tipe of
    TCon (ModuleName.Canonical _ h) n args -> "(" ++ unwords ((Module.toChars h ++ "." ++ N.toChars (T.nameToName n)) : map describe args) ++ ")"
    TFun a b -> "(" ++ describe a ++ " -> " ++ describe b ++ ")"
    TRecord fs e -> "{" ++ concatMap (\(k, v) -> N.toChars k ++ ":" ++ describe v ++ ";") (Map.toList fs) ++ maybe "" (\x -> "|" ++ describe x) e ++ "}"
    TUnit -> "()"
    TPair a b -> "(" ++ describe a ++ "," ++ describe b ++ ")"
    TTriple a b c -> "(" ++ describe a ++ "," ++ describe b ++ "," ++ describe c ++ ")"
    TVar n _ _ -> n
    TAlias (ModuleName.Canonical _ h) n _ r -> "alias:" ++ Module.toChars h ++ "." ++ N.toChars (T.nameToName n) ++ "=" ++ describe r
    TRef _ -> "ref"
    TError -> "error"


-- MATCHING A SCHEME AGAINST AN INSTANCE


type Subst = Map.Map String TType


-- matchT scheme instance: bind every variable of the scheme to the part of the
-- instance it corresponds to. A variable met twice must be bound to equal types
-- (the consistency check); a violation is a Left.
matchT :: TType -> TType -> Either String Subst
matchT scheme inst =
  go Map.empty scheme inst
  where
    go s a b =
      case (a, b) of
        -- the same alias on one side and the plain name on the other (annotations of
        -- other packages may not expand an alias, and aliases may be defined by aliases):
        -- compare the arguments
        (TCon h1 n1 as, _) | Just args <- aliasNamed h1 n1 (length as) b ->
          goList s as args

        (_, TCon h2 n2 bs) | Just args <- aliasNamed h2 n2 (length bs) a ->
          goList s args bs

        _ -> goStripped s a b

    goStripped s a b =
      case (strip a, strip b) of
        (TVar n _ _, i) ->
          case Map.lookup n s of
            Nothing -> Right (Map.insert n i s)
            Just old ->
              if eqT old i
                then Right s
                else
                  -- Elm's row unification lets `{ r | f : t }` overlap a field that r already
                  -- has, so one row variable can legitimately meet a smaller and a larger record
                  case overlapping old i of
                    Just larger -> Right (Map.insert n larger s)
                    Nothing -> Left ("variable " ++ n ++ " is bound to two different types: " ++ describe old ++ " and " ++ describe i)

        (TCon h1 n1 as, TCon h2 n2 bs)
          | h1 == h2 && n1 == n2 && length as == length bs -> goList s as bs

        (TFun a1 b1, TFun a2 b2) -> goList s [a1, b1] [a2, b2]
        (TUnit, TUnit) -> Right s
        (TPair a1 b1, TPair a2 b2) -> goList s [a1, b1] [a2, b2]
        (TTriple a1 b1 c1, TTriple a2 b2 c2) -> goList s [a1, b1, c1] [a2, b2, c2]

        (TRecord f1 e1, TRecord f2 e2) ->
          if not (Map.isSubmapOfBy (\_ _ -> True) f1 f2)
            then Left "record: scheme has a field the instance lacks"
            else
              do  s1 <- goList s (Map.elems f1) (Map.elems (Map.intersection f2 f1))
                  let residual = Map.difference f2 f1
                  case e1 of
                    Nothing ->
                      if Map.null residual && isClosed e2
                        then Right s1
                        else Left "record: closed scheme against a record with more fields"

                    Just ext ->
                      go s1 ext (normRecord residual e2)

        (TRef k1, TRef k2) | k1 == k2 -> Right s
        (x, y) -> Left ("shapes differ: " ++ shape x ++ " against " ++ shape y ++ ": " ++ describe x ++ " against " ++ describe y)

    -- an alias with this head somewhere in the chain of aliases of a type
    aliasNamed h n arity t =
      case t of
        TAlias h2 n2 args real
          | h == h2 && n == n2 && length args == arity -> Just (map snd args)
          | otherwise -> aliasNamed h n arity real
        _ -> Nothing

    -- a record without fields but with a row variable is that variable
    normRecord fields ext =
      case ext of
        Just v | Map.null fields -> v
        _ -> TRecord fields ext

    -- two open or closed records, one with all the fields of the other, same types on the shared fields
    overlapping x y =
      case (asRecord x, asRecord y) of
        (Just (TRecord f1 e1), Just (TRecord f2 e2))
          | sameRow e1 e2 && agree f1 f2 ->
              Just (if Map.size f1 >= Map.size f2 then strip x else strip y)
        _ -> Nothing

    -- a bare row variable is a record without fields
    asRecord t =
      case strip t of
        r@(TRecord _ _) -> Just r
        v@(TVar _ _ _)  -> Just (TRecord Map.empty (Just v))
        _               -> Nothing

    agree f1 f2 =
      let common = Map.intersectionWith eqT f1 f2
          (small, big) = if Map.size f1 <= Map.size f2 then (f1, f2) else (f2, f1)
      in and (Map.elems common) && Map.isSubmapOfBy (\_ _ -> True) small big

    sameRow (Just a) (Just b) = eqT a b
    sameRow Nothing Nothing = True
    sameRow _ _ = False

    goList s as bs =
      case (as, bs) of
        (x:xs, y:ys) -> do { s1 <- go s x y; goList s1 xs ys }
        _            -> Right s

    isClosed e =
      case e of
        Nothing -> True
        Just _  -> False

    shape t =
      case t of
        TCon _ _ _ -> "constructor"
        TFun _ _ -> "function"
        TRecord _ _ -> "record"
        TUnit -> "unit"
        TPair _ _ -> "pair"
        TTriple _ _ _ -> "triple"
        TVar _ _ _ -> "variable"
        TAlias _ _ _ _ -> "alias"
        TRef _ -> "reference"
        TError -> "error"
