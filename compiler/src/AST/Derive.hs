-- Ficcus (A4a): the `derive` line of a custom type (docs/A4-DERIVE-DESIGN.md).
--
--     type Color = Red | Green | Blue
--         where
--             derive compare, hash, toString
--
-- The parser keeps a `derive` line as a value of the module named `$derive$Color` whose body is the list of the
-- member names (`[compare, hash, toString]`, each with its region).  `$` cannot occur in a name of a program, and the
-- name has no `$$`, so it is never taken for a member.  Canonicalize.Derive takes these values out before anything
-- else sees them, checks them, and replaces each listed member by an ordinary member `Color$$compare` with a
-- synthesized signature.  In A4a its body is a stub (`Elm.Kernel.FicDerive.<Type.member>`) that the C generator
-- refuses; the bodies come with the slices A4b to A4f.
module AST.Derive
  ( placeholder
  , lineName
  , lineType
  , Line(..)
  , lineOf
  , known
  , isEnumMember
  , needsJson
  , kernelHome
  , stubName
  , stubDisplay
  , markerPrefix
  , marker
  , markerText
  )
  where


import qualified Data.List as List

import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeName as T
import qualified AST.Source as Src
import qualified Reporting.Annotation as A
import qualified String as S



-- THE LINE AS A VALUE


-- | the name the parser gives a `derive` line before it knows the type (Parse.Members.mangleMember renames it)
placeholder :: N.Name
placeholder =
  fromChars "$derive"


-- | `$derive$Color`
lineName :: T.Name -> N.Name
lineName tipe =
  fromChars (prefix ++ T.nameToChars tipe)


prefix :: String
prefix = "$derive$"


-- | the type of a `derive` line value, Nothing for any other value
lineType :: N.Name -> Maybe String
lineType name =
  List.stripPrefix prefix (N.toChars name)


-- | a `derive` line: the region of the line, the type, the members as written
data Line =
  Line
    { _region :: A.Region
    , _type :: String
    , _members :: [A.Located N.Name]
    }


lineOf :: A.Located Src.Value -> Maybe Line
lineOf (A.At region (Src.Value (A.At _ name) _ (A.At _ body) _)) =
  case (lineType name, body) of
    (Just tipe, Src.List items) -> Just (Line region tipe [ A.At r n | A.At r (Src.Var _ n) <- items ])
    _ -> Nothing



-- THE MEMBERS


-- | the members that can be derived, in the order of the design note (group S, then group E)
known :: [String]
known =
  [ "compare", "hash", "toString", "fromString"
  , "encode", "decoder", "minValue", "maxValue", "succ", "pred", "enumerate", "map"
  ]


-- | the members that only an enumeration type (every constructor without fields) can derive
isEnumMember :: String -> Bool
isEnumMember member =
  member `elem` ["minValue", "maxValue", "succ", "pred", "enumerate"]


-- | the modules of elm/json that the signature of the member mentions
needsJson :: String -> [String]
needsJson member =
  case member of
    "encode" -> ["Json.Encode"]
    "decoder" -> ["Json.Decode"]
    _ -> []



-- THE STUB BODY (A4a)


-- | the kernel module of the stubs: `Elm.Kernel.FicDerive.Color.compare`
kernelHome :: String
kernelHome = "FicDerive"


-- | the kernel name of the stub of `Color.compare`
stubName :: String -> String -> N.Name
stubName tipe member =
  fromChars (tipe ++ "." ++ member)


-- | the kernel names of stubs are `Type.member`: the member as the user writes it
stubDisplay :: N.Name -> String
stubDisplay =
  N.toChars



-- THE MARKER (the JavaScript output refuses a module with a derive line, Nitpick.Constraints)


markerPrefix :: String
markerPrefix = "$derived$"


-- | `$derived$Color$compare,hash`: one node per type with a derive line, in the object graph of its module
marker :: String -> [String] -> N.Name
marker tipe members =
  fromChars (markerPrefix ++ tipe ++ "$" ++ List.intercalate "," members)


-- | `Color derives compare, hash` for a marker name (Nothing: not a marker)
markerText :: N.Name -> Maybe (String, String)
markerText name =
  case List.stripPrefix markerPrefix (N.toChars name) of
    Just rest ->
      let (tipe, members) = break (== '$') rest in
      Just (tipe, List.intercalate ", " (splitOn ',' (drop 1 members)))
    Nothing ->
      Nothing


splitOn :: Char -> String -> [String]
splitOn c s =
  case break (== c) s of
    (a, []) -> [a]
    (a, _ : rest) -> a : splitOn c rest



-- HELPERS


fromChars :: String -> N.Name
fromChars =
  N.fromString . S.fromChars
