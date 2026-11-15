-- Ficcus (ATTACH, stage A1): members attached to custom types, in the canonicalizer.
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


-- | the keys under which the members of the type `tipe`, of a module imported as `prefix`, are
-- reachable: `Prefix.Type`, and `Prefix` itself when the type is named like the last part of the module
importKeys :: Module.Prefix -> Module.Name -> T.Name -> [Module.Prefix]
importKeys prefix moduleName tipe =
  let
    tipeChars = T.nameToChars tipe
    lastPart = reverse (takeWhile (/= '.') (reverse (Module.toChars moduleName)))
  in
  Members.typeKeyOf prefix tipeChars
    : [ Members.typeKey (Module.prefixToChars prefix) | lastPart == tipeChars ]



-- | the key of a type that is in scope under its own name
exposedKey :: T.Name -> Module.Prefix
exposedKey tipe =
  Members.typeKey (T.nameToChars tipe)



-- RESOLUTION


data Resolution
  = NotMember                                 -- not a reference to a member: Elm's own lookup goes on
  | LocalMember N.Name                        -- the mangled name of a member of a type of this module
  | ForeignMember ModuleName.Canonical N.Name Can.Annotation   -- the mangled name
  | AmbiguousMember ModuleName.Canonical (OneOrMore.OneOrMore ModuleName.Canonical)
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
              (_, Env.Specific h1 _) : (_, Env.Specific h2 _) : _ -> AmbiguousMember h1 (OneOrMore.one h2)
              (_, Env.Specific h1 _) : (_, Env.Ambiguous h2 _) : _ -> AmbiguousMember h1 (OneOrMore.one h2)
              (_, Env.Ambiguous h hs) : _         -> AmbiguousMember h hs
              []
                | isModule  -> NotMember
                | otherwise -> UnknownMember chars (List.sort (Members.membersOf' (Map.keys qualified)))

          Nothing ->
            -- only a type that has members here gets the member error: for any other prefix Elm's own error stays
            case List.sort (Members.membersOf chars (Map.keys vs)) of
              []      -> NotMember
              members -> if isModule then NotMember else UnknownMember chars members


tname :: String -> T.Name
tname =
  T.nameFromString . S.fromChars
