-- Ficus (ATTACH, stage A1): members attached to custom types, in the canonicalizer.
--
-- A member `add` of `Money` is the top level definition `Money$$add` (see AST.Members).  This module
--   * sorts the values of an interface into plain values and members,
--   * enters the members of an imported type in the table of qualified variables under the key
--     `Money$` (AST.Members.typeKey), and
--   * resolves a qualified name `A.f` that is not a module or alias path to a member of the type `A`.
-- The exact rules are in docs/attach/A1-NOTES.md.
module Canonicalize.Members
  ( partitionDefs
  , importKeys
  , memberEnv
  , siblingName
  , exposedKey
  , Resolution(..)
  , resolve
  )
  where


import qualified Data.List as List
import qualified Data.Map.Strict as Map

import qualified AST.Canonical as Can
import qualified AST.Members as Members
import qualified AST.Prim.Module as Module
import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeName as T
import qualified Canonicalize.Environment as Env
import qualified Data.OneOrMore as OneOrMore
import qualified Elm.ModuleName as ModuleName
import qualified String as S



-- IMPORTS


-- | the values of an interface without the members, and the members (under their mangled names) by type name
partitionDefs :: Map.Map N.Name a -> (Map.Map N.Name a, Map.Map String (Map.Map N.Name a))
partitionDefs defs =
  Map.foldrWithKey add (Map.empty, Map.empty) defs
  where
    add name value (plain, members) =
      case Members.split name of
        Nothing                -> (Map.insert name value plain, members)
        Just (tipe, _)         -> (plain, Map.insertWith Map.union tipe (Map.singleton name value) members)


-- | the key under which the members of the type `tipe`, of a module imported as `prefix`, are
-- reachable: `Prefix.Type` (`Finance.Money.Money.add`, or `FM.Money.add` with `import Finance.Money as FM`)
importKeys :: Module.Prefix -> T.Name -> [Module.Prefix]
importKeys prefix tipe =
  [ Members.typeKeyOf prefix (T.nameToChars tipe) ]



-- | the key of a type that is in scope under its own name
exposedKey :: T.Name -> Module.Prefix
exposedKey tipe =
  Members.typeKey (T.nameToChars tipe)



-- RESOLUTION


data Resolution
  = NotMember                                 -- not a reference to a member: Elm's own lookup goes on
  | LocalMember N.Name                        -- the mangled name of a member of a type of this module
  | ForeignMember ModuleName.Canonical N.Name Can.Annotation   -- the mangled name
  | AmbiguousMember String ModuleName.Canonical (OneOrMore.OneOrMore ModuleName.Canonical)   -- the name of the type
  | UnknownMember String [N.Name]             -- the type is in scope but has no such member: the members it has


-- | `prefix.name`: a member of the type `prefix`.  Elm's first rule has priority: when `prefix` is a
-- module or alias that has `name`, this is not a member reference.
resolve :: Env.Env -> Module.Prefix -> N.Name -> Resolution
resolve (Env.Env _ vs _ _ _ qvs _ _) prefix name =
  let
    chars = Module.prefixToChars prefix
    mangled = Members.mangle (tname chars) name
    isModule = Map.member prefix qvs
    isNamed k = fmap snd (Members.split k) == Just name
    inModule = case Map.lookup prefix qvs of { Just q -> Map.member name q ; Nothing -> False }
  in
  if inModule || '$' `elem` chars then
    NotMember

  else
    case Map.lookup mangled vs of
      Just (Env.TopLevel _) | '.' `notElem` chars ->
        LocalMember mangled

      _ ->
        case Map.lookup (Members.typeKey chars) qvs of
          Just qualified ->
            case [ (k, info) | (k, info) <- Map.toList qualified, isNamed k ] of
              [(k, Env.Specific home annotation)] -> ForeignMember home k annotation
              (_, Env.Ambiguous h hs) : _         -> AmbiguousMember (lastPart chars) h hs
              (_, Env.Specific h _) : _ : _       -> AmbiguousMember (lastPart chars) h (OneOrMore.one h)   -- (one key holds one type name: not reached)
              []
                | isModule  -> NotMember
                | otherwise -> UnknownMember chars (List.sort (Members.membersOf' (Map.keys qualified)))

          Nothing ->
            -- only a type that has members here gets the member error: for any other prefix Elm's own error stays
            case List.sort (Members.membersOf chars (Map.keys vs)) of
              []      -> NotMember
              members -> if isModule then NotMember else UnknownMember chars members


lastPart :: String -> String
lastPart chars =
  reverse (takeWhile (/= '.') (reverse chars))



-- SIBLINGS (A1b)
--
-- Inside the `where` block of the type T the members of T are visible under their plain names, and win
-- over a top level function or an imported name that is spelled the same.  While a member is canonicalized,
-- its environment maps each plain sibling name to a top level entry, and the entry `$` says which type the
-- block belongs to; `siblingName` then gives the real (mangled) name of a top level name.


markerName :: N.Name
markerName =
  N.fromString (S.fromChars "$")


-- | the environment for the body of the definition `name`: changed only when it is a member
memberEnv :: N.Name -> Env.Env -> Env.Env
memberEnv name env@(Env.Env home vs ts cs bs qvs qts qcs) =
  case Members.split name of
    Nothing ->
      env

    Just (tipe, _) ->
      let
        siblings = [ (member, var) | (k, var@(Env.TopLevel _)) <- Map.toList vs, Just (t, member) <- [Members.split k], t == tipe ]
        marker = Env.Foreign home (Can.Forall Map.empty (Can.TType home (tname tipe) []))
        vs2 = Map.insert markerName marker (foldr (\(member, var) -> Map.insert member var) vs siblings)
      in
      Env.Env home vs2 ts cs bs qvs qts qcs


-- | the top level definition that the plain name `name` means: the member of the type whose `where`
-- block is being canonicalized, if it has one of this name
siblingName :: Map.Map N.Name Env.Var -> N.Name -> N.Name
siblingName vs name =
  case Map.lookup markerName vs of
    Just (Env.Foreign _ (Can.Forall _ (Can.TType _ tipe _))) ->
      let mangled = Members.mangle tipe name in
      if Map.member mangled vs then mangled else name

    _ ->
      name


tname :: String -> T.Name
tname =
  T.nameFromString . S.fromChars
