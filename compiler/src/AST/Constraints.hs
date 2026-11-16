{-# LANGUAGE PatternGuards #-}
-- Ficcus (ATTACH, stage A2): constraints on the type variables of a signature.
--
--     sum : List a -> a
--         where
--             a has zero : a
--             a has add : a -> a -> a
--     sum xs = List.foldl add zero xs
--
-- A constrained definition is an ordinary definition with one hidden leading parameter per constraint:
--
--     sum : a -> (a -> a -> a) -> List a -> a
--     sum (a$has$zero as zero) (a$has$add as add) xs = ...
--
-- The pattern `(a$has$zero as zero)` is the mark (`$` cannot occur in a name of a program): it says which
-- variable needs which member, and binds the name the body uses.  For its users the function has the
-- constrained scheme, an annotation whose type is wrapped in a type constructor that cannot be written:
--
--     $where (List a -> a) ($has$zero a a) ($has$add a (a -> a -> a))
--
-- See docs/attach/A2-DESIGN.md.
module AST.Constraints
  ( Hidden(..)
  , marker
  , splitMarker
  , whereKey
  , hiddenOfDef
  , hiddenCount
  , wrap
  , wrapDef
  , Required(..)
  , unwrap
  , isWrapped
  , fullType
  , whereName
  , hasMember
  )
  where


import qualified Data.List as List

import qualified AST.Canonical as Can
import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeName as T
import qualified AST.Prim.TypeVar as TV
import qualified Elm.ModuleName as ModuleName
import qualified Reporting.Annotation as A
import qualified String as S



-- NAMES


-- | a hidden parameter: the type variable, the member it needs, the name the body uses
data Hidden =
  Hidden
    { _var :: String
    , _member :: N.Name
    , _local :: N.Name
    }


-- | `a$has$add`: the name of the hidden parameter for `a has add`
marker :: String -> N.Name -> N.Name
marker var member =
  fromChars (var ++ infix_ ++ N.toChars member)


infix_ :: String
infix_ = "$has$"


splitMarker :: N.Name -> Maybe (String, N.Name)
splitMarker name =
  go [] (N.toChars name)
  where
    go _ [] = Nothing
    go acc rest@(c:cs)
      | infix_ `List.isPrefixOf` rest && not (null acc) = Just (reverse acc, fromChars (drop (length infix_) rest))
      | otherwise = go (c:acc) cs


-- | the key under which the canonicalizer keeps the constrained scheme of the top level definition `name`
whereKey :: N.Name -> N.Name
whereKey name =
  fromChars (N.toChars name ++ "$where")



-- DEFINITIONS


-- | the hidden parameters of a definition, in order (empty for an ordinary definition)
hiddenOfDef :: Can.Def -> [Hidden]
hiddenOfDef def =
  case def of
    Can.Def _ _ _ -> []
    Can.TypedDef _ _ args _ _ -> go (map fst args)
  where
    go patterns =
      case patterns of
        A.At _ (Can.PAlias (A.At _ (Can.PVar m)) local) : rest | Just (var, member) <- splitMarker m ->
          Hidden var member local : go rest
        _ ->
          []


hiddenCount :: Can.Def -> Int
hiddenCount =
  length . hiddenOfDef



-- THE CONSTRAINED SCHEME


whereName :: T.Name
whereName =
  T.nameFromString (S.fromChars "$where")


hasPrefix :: String
hasPrefix = "$has$"


-- | from the type with the hidden parameters (`m1 -> ... -> mk -> real`) to the constrained scheme
wrap :: [Hidden] -> Can.Annotation -> Can.Annotation
wrap hidden annotation@(Can.Forall freeVars tipe) =
  case hidden of
    [] -> annotation
    _  -> Can.Forall freeVars (go hidden tipe [])
  where
    home = ModuleName.basics
    go hs t acc =
      case (hs, t) of
        (Hidden var member _ : rest, Can.TLambda m result) ->
          go rest result (Can.TType home (T.nameFromString (S.fromChars (hasPrefix ++ N.toChars member))) [Can.TVar (TV.varFromString (S.fromChars var)), m] : acc)
        _ ->
          Can.TType home whereName (t : reverse acc)


-- | the constrained scheme of a definition, from the annotation the type checker gives it
wrapDef :: Can.Def -> Can.Annotation -> Can.Annotation
wrapDef def annotation =
  wrap (hiddenOfDef def) annotation


-- | a required member: its name, the variable that must have it, its type
data Required =
  Required
    { _r_member :: N.Name
    , _r_subject :: Can.Type
    , _r_type :: Can.Type
    }


isWrapped :: Can.Type -> Bool
isWrapped tipe =
  case tipe of
    Can.TType _ name (_ : _) -> name == whereName
    _ -> False


-- | the real type and the required members of a constrained scheme
unwrap :: Can.Type -> Maybe (Can.Type, [Required])
unwrap tipe =
  case tipe of
    Can.TType _ name (real : hs) | name == whereName ->
      Just (real, [ Required member subject t | Can.TType _ hname [subject, t] <- hs, Just member <- [hasMember hname] ])
    _ ->
      Nothing


-- | `add` for the type name `$has$add`
hasMember :: T.Name -> Maybe N.Name
hasMember name =
  fmap fromChars (List.stripPrefix hasPrefix (T.nameToChars name))


-- | the type with the hidden parameters of a constrained scheme (the type the definition itself has)
fullType :: Can.Type -> Can.Type
fullType tipe =
  case unwrap tipe of
    Just (real, required) -> foldr (\(Required _ _ t) acc -> Can.TLambda t acc) real required
    Nothing -> tipe



-- HELPERS


fromChars :: String -> N.Name
fromChars =
  N.fromString . S.fromChars
