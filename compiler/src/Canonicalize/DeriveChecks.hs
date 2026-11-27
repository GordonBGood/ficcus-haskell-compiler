{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE PatternGuards #-}
-- Ficcus (A4bf, the A4b review's M1, F2, F3): checks of a `derive` line that Canonicalize.Derive calls.
--
--   nonRegularGroup:  (M1) a type of the line used at growing arguments through the other types of its module that refer to it
--     (`type A a = A a (B (List a))`, `type B a = B (A a)`): the derived member would be needed at infinitely many exact types.
--     The deriver's own check (`Derive.nonRegular`) sees only the type inside its own fields.
--   writtenShape:  (F2) a part whose written `compare`/`hash` has another type than a derived member calls (`hash : T -> String`).
--   besideEq:  (F3) `derive compare`/`derive hash` on a type whose `where` block writes `eq`: the derived member would disagree
--     with the written equality (equal values that compare unequal or hash apart).
module Canonicalize.DeriveChecks
  ( nonRegularGroup
  , writtenShape
  , besideEq
  )
  where


import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import qualified AST.Canonical as Can
import qualified AST.Constraints as Constraints
import qualified AST.Members as Members
import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeName as T
import qualified AST.Prim.TypeVar as TV
import qualified AST.Source as Src
import qualified AST.Utils.Type as Type
import qualified AST.WellKnown as WK
import qualified Elm.ModuleName as ModuleName
import qualified Reporting.Annotation as A
import qualified String as S



-- M1: THE MUTUAL GROUP


-- | the first use, inside the group of types of the module that refer to `tipe` and that it refers to, of a type of the group at
-- other arguments than the walk from `tipe` at its own parameters reached it with first (`tipe` itself: at other arguments than
-- its parameters, as `Derive.nonRegular` asks for its own fields): the use (with the arguments put in) and the type whose
-- field holds it.  Like `Derive.nonRegular`, this is conservative: `type A a = A (B Int) (B a)` is refused when `B` refers
-- back to `A`, although its instances are finite.
nonRegularGroup :: ModuleName.Canonical -> Map.Map T.Name Can.Union -> T.Name -> Maybe (Can.Type, T.Name)
nonRegularGroup home unions tipe =
  case Map.lookup tipe unions of
    Nothing -> Nothing
    Just (Can.Union vars _ _ _) ->
      walk (Map.singleton tipe (map Can.TVar vars)) [(tipe, map Can.TVar vars)]
  where
    group = Set.filter (\n -> Set.member tipe (reach n)) (reach tipe)

    -- the union names of the module that the fields of a union refer to, transitively
    reach start =
      go Set.empty [start]
      where
        go seen [] = seen
        go seen (n : rest) =
          let next = [ m | m <- refsOf n, not (Set.member m seen) ] in
          go (foldr Set.insert seen next) (next ++ rest)

    refsOf n =
      case Map.lookup n unions of
        Nothing -> []
        Just (Can.Union _ ctors _ _) -> [ m | Can.Ctor _ _ _ args <- ctors, arg <- args, (m, _) <- uses arg ]

    -- the uses of the module's unions in a type, with their arguments
    uses t =
      case t of
        Can.TType h n args
          | h == home && Map.member n unions -> (n, args) : concatMap uses args
          | otherwise -> concatMap uses args
        Can.TLambda a b -> uses a ++ uses b
        Can.TRecord fields _ -> concatMap (\(Can.FieldType _ ft) -> uses ft) (Map.elems fields)
        Can.TPair a b -> uses a ++ uses b
        Can.TTriple a b c -> uses a ++ uses b ++ uses c
        Can.TAlias _ _ args aliasType -> uses (Type.dealias args aliasType)
        Can.TVar _ -> []
        Can.TUnit -> []

    walk _ [] = Nothing
    walk seen ((n, args) : rest) =
      case Map.lookup n unions of
        Nothing -> walk seen rest
        Just (Can.Union vars ctors _ _) ->
          let
            sub = Map.fromList (zip vars args)
            found = [ (m, as) | Can.Ctor _ _ _ fields <- ctors, f <- fields, (m, as) <- uses (substitute sub f), Set.member m group ]
          in
          step seen n found rest

    step seen inside found rest =
      case found of
        [] -> walk seen rest
        (m, as) : more ->
          case Map.lookup m seen of
            Just earlier
              | earlier == as -> step seen inside more rest
              | otherwise -> Just (Can.TType home m as, inside)
            Nothing ->
              step (Map.insert m as seen) inside more (rest ++ [(m, as)])


substitute :: Map.Map TV.Var Can.Type -> Can.Type -> Can.Type
substitute sub t =
  case t of
    Can.TVar v -> Map.findWithDefault t v sub
    Can.TType h n args -> Can.TType h n (map again args)
    Can.TLambda a b -> Can.TLambda (again a) (again b)
    Can.TRecord fields ext -> Can.TRecord (Map.map (\(Can.FieldType i ft) -> Can.FieldType i (again ft)) fields) ext
    Can.TPair a b -> Can.TPair (again a) (again b)
    Can.TTriple a b c -> Can.TTriple (again a) (again b) (again c)
    Can.TAlias _ _ args aliasType -> again (Type.dealias args aliasType)
    Can.TUnit -> Can.TUnit
  where
    again = substitute sub



-- F2: THE SHAPE OF A WRITTEN MEMBER


-- | the written type of the member of the type `home.name` when it has not the shape a derived member calls it with
-- (`compare : T -> T -> Order`, `hash : T -> Int`; the hidden parameters of its `where` lines aside); Nothing when it has
-- it, or when the member is not one of those
writtenShape :: String -> ModuleName.Canonical -> T.Name -> Can.Annotation -> Maybe (Can.Type, String)
writtenShape member home name (Can.Forall _ wrapped) =
  case shape of
    Nothing -> Nothing
    Just s ->
      let real = deepDealias (maybe wrapped fst (Constraints.unwrap wrapped)) in
      if WK.fits home name s real then Nothing else Just (real, WK.expectedText s (T.nameToChars name))
  where
    shape =
      case member of
        "compare" -> Just WK.Compare
        "hash" -> Just WK.Hash
        _ -> Nothing


deepDealias :: Can.Type -> Can.Type
deepDealias t =
  case t of
    Can.TAlias _ _ args aliasType -> deepDealias (Type.dealias args aliasType)
    Can.TType h n args -> Can.TType h n (map deepDealias args)
    Can.TLambda a b -> Can.TLambda (deepDealias a) (deepDealias b)
    Can.TRecord fields ext -> Can.TRecord (Map.map (\(Can.FieldType i ft) -> Can.FieldType i (deepDealias ft)) fields) ext
    Can.TPair a b -> Can.TPair (deepDealias a) (deepDealias b)
    Can.TTriple a b c -> Can.TTriple (deepDealias a) (deepDealias b) (deepDealias c)
    Can.TVar _ -> t
    Can.TUnit -> t



-- F3: BESIDE A WRITTEN `eq`


-- | the region of the written `eq` of the type, when the member is `compare` or `hash` and the `where` block writes `eq`
besideEq :: [A.Located Src.Value] -> T.Name -> String -> Maybe A.Region
besideEq values tipe member
  | member `elem` ["compare", "hash"] =
      case [ r | A.At _ (Src.Value (A.At r n) _ _ _) <- values, n == Members.mangle tipe eq ] of
        written : _ -> Just written
        [] -> Nothing
  | otherwise =
      Nothing
  where
    eq = N.fromString (S.fromChars "eq")
