-- Ficcus (ATTACH, stage A1): names of members attached to custom types.
--
-- A member `add` of the type `Money` is an ordinary top level definition whose name is `Money$$add`.
-- `$` cannot occur in an Elm name, so no program can write (or clash with) such a name, and every later
-- phase (type checker, optimizer, JavaScript and C generators, interfaces) treats a member as the plain
-- top level function it is.  See docs/attach/A1-NOTES.md.
module AST.Members
  ( mangle
  , split
  , isMember
  , membersOf
  , membersOf'
  , typeKey
  , typeKeyOf
  , displayName
  , homeChars
  , typeId
  , isForeign
  , foreignName
  )
  where


import qualified Data.List as List

import qualified AST.Prim.Module as Module
import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeName as T
import qualified Elm.ModuleName as ModuleName
import qualified Elm.Package as Pkg
import qualified String as S



-- NAMES


separator :: String
separator = "$$"


-- | the global name of the member `member` of type `tipe`
mangle :: T.Name -> N.Name -> N.Name
mangle tipe member =
  fromChars (T.nameToChars tipe ++ separator ++ N.toChars member)


-- | the type and the member of a mangled name
split :: N.Name -> Maybe (String, N.Name)
split name =
  splitChars (N.toChars name)


splitChars :: String -> Maybe (String, N.Name)
splitChars chars =
  case breakOn chars of
    Just (tipe, member) -> Just (tipe, fromChars member)
    Nothing             -> Nothing


breakOn :: String -> Maybe (String, String)
breakOn chars =
  go [] chars
  where
    go _ [] = Nothing
    go acc rest@(c:cs)
      | separator `List.isPrefixOf` rest = Just (reverse acc, drop (length separator) rest)
      | otherwise                        = go (c:acc) cs


isMember :: N.Name -> Bool
isMember name =
  case split name of
    Just _  -> True
    Nothing -> False


-- | the members (unmangled) among a collection of global names, for the type with this name
membersOf :: String -> [N.Name] -> [N.Name]
membersOf tipe names =
  [ member | name <- names, Just (t, member) <- [split name], t == tipe ]


-- | the members (unmangled) among a collection of global names, whatever their type
membersOf' :: [N.Name] -> [N.Name]
membersOf' names =
  [ member | name <- names, Just (_, member) <- [split name] ]


-- | `Money.add` for the mangled name `Money$$add`, for error messages
displayName :: N.Name -> String
displayName name =
  case split name of
    Just (tipe, member) -> tipe ++ "." ++ N.toChars member
    Nothing             -> N.toChars name



-- MEMBERS OF TYPES FROM OTHER MODULES
--
-- (A2) A constraint at a type needs the members of that type wherever the type is known, not only where its
-- module is imported.  An interface therefore also carries, for the types its own exports mention, the
-- members of those types under the name `pkg:Module.Type$$member`.  Such a name has a `:` before the `$$`,
-- and is never a plain value or a member of a type of the interface's own module.


-- | `elm/core:Basics`, the id the specializer and the solver table use for a module
homeChars :: ModuleName.Canonical -> String
homeChars (ModuleName.Canonical pkg name) =
  Pkg.toChars pkg ++ ":" ++ Module.toChars name


-- | `pkg:Module.Type`
typeId :: ModuleName.Canonical -> T.Name -> String
typeId home tipe =
  homeChars home ++ "." ++ T.nameToChars tipe


-- | a name of the form `pkg:Module.Type$$member`
isForeign :: N.Name -> Bool
isForeign name =
  case split name of
    Just (tipe, _) -> ':' `elem` tipe
    Nothing        -> False


foreignName :: String -> N.Name -> N.Name
foreignName tipeId member =
  fromChars (tipeId ++ separator ++ N.toChars member)



-- QUALIFIER KEYS
--
-- The members of the type `Money` are entered in the table of qualified variables under the key
-- `Money$` (or `Fm.Money$` for a type reached through the module alias `Fm`).  `$` cannot occur in a
-- module name either, so the key never clashes with a module or alias.


typeKey :: String -> Module.Prefix
typeKey chars =
  Module.toPrefix (Module.fromString (S.fromChars (chars ++ "$")))


typeKeyOf :: Module.Prefix -> String -> Module.Prefix
typeKeyOf prefix tipe =
  typeKey (Module.prefixToChars prefix ++ "." ++ tipe)



-- HELPERS


fromChars :: String -> N.Name
fromChars =
  N.fromString . S.fromChars
