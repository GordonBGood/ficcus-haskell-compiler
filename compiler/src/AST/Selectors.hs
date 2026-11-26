-- Ficcus (A5b, docs/A5-INFERENCE-DESIGN.md section 2): bare names of attached functions (selectors).
--
-- An unqualified `add` that no variable binds (Elm would report NAMING ERROR) means the attached function `add` of
-- whatever type the use is at, when a type with a `where` block that the module defines or imports has one.  There is
-- no new expression node: the selector is
--
--     Can.VarForeign attachedHome add ($where t $inferred ($has$add a t))
--
-- a use of a function of a module that cannot exist (`$attached`), with an inferred constrained scheme: its type `t` is
-- the type of the member, and its one requirement says that the subject `a` has the member at that type.  The solver
-- turns it into that requirement (Type.Members.use, as for a call of a constrained function); the specializer calls
-- the member of the subject's exact type (Ficcus.Mono.Spec); the JavaScript output refuses it (Nitpick.Constraints).
module AST.Selectors
  ( attachedHome
  , isAttachedHome
  , isSelectorId
  , selectorKey
  , scheme
  , Parts(..)
  , parts
  )
  where


import qualified Data.List as List
import qualified Data.Map.Strict as Map

import qualified AST.Canonical as Can
import qualified AST.Constraints as Constraints
import qualified AST.Prim.Module as Module
import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeVar as TV
import qualified Elm.ModuleName as ModuleName
import qualified Elm.Package as Pkg
import qualified String as S



-- THE RESERVED HOME


-- | `elm/core:$attached`: `$` cannot occur in a module name, so no module has this home
attachedHome :: ModuleName.Canonical
attachedHome =
  ModuleName.Canonical Pkg.core (Module.fromString (S.fromChars homeName))


homeName :: String
homeName = "$attached"


isAttachedHome :: ModuleName.Canonical -> Bool
isAttachedHome home =
  home == attachedHome


-- | the id the specializer and the type dumps give a selector: `elm/core:$attached.add`
isSelectorId :: String -> Bool
isSelectorId cid =
  ("elm/core:" ++ homeName ++ ".") `List.isPrefixOf` cid



-- THE ENVIRONMENT KEY


-- | the key under which the canonicalizer keeps the selector `name` (Canonicalize.Selectors): `add$selector`, a name no
-- program can write
selectorKey :: N.Name -> N.Name
selectorKey name =
  N.fromString (S.fromChars (N.toChars name ++ "$selector"))



-- THE SCHEME


-- | the scheme of the selector `member` with the subject `subject` and the member type `tipe` (its free variables
-- include the subject)
scheme :: N.Name -> TV.Var -> Can.Type -> Can.Annotation
scheme member subject tipe =
  Can.Forall (Map.fromList [ (v, ()) | v <- vars tipe ]) $
    Can.TType ModuleName.basics Constraints.whereName
      [ tipe
      , Can.TType ModuleName.basics Constraints.inferredName []
      , Can.TType ModuleName.basics (Constraints.hasTypeName member) [Can.TVar subject, tipe]
      ]


-- | what a selector's scheme says: the member, the name of the subject variable, the member type
data Parts =
  Parts
    { _member :: N.Name
    , _subject :: String
    , _type :: Can.Type
    }


parts :: Can.Annotation -> Maybe Parts
parts (Can.Forall _ tipe) =
  case Constraints.unwrap tipe of
    Just (real, [Constraints.Required member (Can.TVar subject) _]) -> Just (Parts member (TV.varToChars subject) real)
    _ -> Nothing


vars :: Can.Type -> [TV.Var]
vars tipe =
  List.nub (go tipe)
  where
    go t =
      case t of
        Can.TLambda a b -> go a ++ go b
        Can.TVar v -> [v]
        Can.TType _ _ args -> concatMap go args
        Can.TRecord fields ext -> concat [ go x | Can.FieldType _ x <- Map.elems fields ] ++ maybe [] (: []) ext
        Can.TUnit -> []
        Can.TPair a b -> go a ++ go b
        Can.TTriple a b c -> go a ++ go b ++ go c
        Can.TAlias _ _ args _ -> concatMap (go . snd) args
