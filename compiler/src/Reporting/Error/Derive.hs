{-# LANGUAGE OverloadedStrings #-}
-- Ficcus (A4a): the errors of a `derive` line (docs/A4-DERIVE-DESIGN.md, section 1); Canonicalize.Derive finds them.
module Reporting.Error.Derive
  ( Error(..)
  , Reason(..)
  , toReport
  )
  where


import qualified Data.List as List

import qualified AST.Derive as Derive
import qualified Reporting.Annotation as A
import qualified Reporting.Doc as D
import qualified Reporting.Render.Code as Code
import qualified Reporting.Report as Report
import qualified Reporting.Suggest as Suggest



-- ERRORS (types and members as the user writes them)


data Error
  = Unknown A.Region String String                  -- the type, the member
  | Twice A.Region A.Region String String           -- the first and the second mention; the type, the member
  | TwoLines A.Region A.Region String               -- the first and the second line; the type
  | AndDefine A.Region A.Region String String       -- the member in the derive line, the written member; the type, the member
  | Shadowed A.Region A.Region String String String -- the member in the derive line, the top level definition; the module, the type, the member
  | Cannot A.Region String String Reason            -- the member in the derive line; the type, the member
  | NonEnumeration A.Region String String String    -- the type, the member, a constructor with fields
  | BesideEq A.Region A.Region String String        -- (A4bf) the member in the derive line, the written `eq`; the type, the member


-- | why a member cannot be derived
data Reason
  = Lacks String String (Maybe String)   -- the path to the part (`Contact > email`), the type of the part, the custom type to give the member
  | NotYet String String String          -- the path, the type of the part, what is missing
  | NonRegular String                    -- the use of the type inside itself at other arguments
  | NonRegularGroup String String String -- (A4bf) the use of a type of its group at other arguments, that type, the type whose field has it
  | WrongShape String String String String String   -- (A4bf) the path, the type of the part, its member, the member's type, the type needed
  | NoParameter



-- REPORTS


toReport :: Code.Source -> Error -> Report.Report
toReport source err =
  case err of
    Unknown region tipe member ->
      Report.Report "UNKNOWN DERIVED MEMBER" region [] $
        Code.toSnippet source region Nothing
          (
            D.reflow $ "The type `" ++ tipe ++ "` cannot derive `" ++ member ++ "`: it is not an attached function the compiler can write."
          ,
            D.stack
              [ D.reflow $ "These are the functions a `derive` line can list: " ++ commas Derive.known ++ "."
              , hint member
              ]
          )

    Twice first second tipe member ->
      Report.Report "DERIVED TWICE" second [] $
        Code.toPair source first second
          (
            D.reflow $ "The `derive` line of `" ++ tipe ++ "` lists `" ++ member ++ "` twice."
          ,
            "Remove one of them."
          )
          (
            D.reflow $ "The `derive` line of `" ++ tipe ++ "` lists `" ++ member ++ "` here:"
          ,
            "and again here:"
          ,
            "Remove one of them."
          )

    TwoLines first second tipe ->
      Report.Report "DERIVED TWICE" second [] $
        Code.toPair source first second
          (
            D.reflow $ "The type `" ++ tipe ++ "` has two `derive` lines."
          ,
            "A type has one `derive` line, which lists all its derived functions. Join them."
          )
          (
            D.reflow $ "The type `" ++ tipe ++ "` has a `derive` line here:"
          ,
            "and another one here:"
          ,
            "A type has one `derive` line, which lists all its derived functions. Join them."
          )

    AndDefine derived written tipe member ->
      Report.Report "DERIVE AND DEFINE" written [] $
        Code.toPair source derived written
          (
            D.reflow $ "The type `" ++ tipe ++ "` both derives `" ++ member ++ "` and defines it."
          ,
            pickOne tipe member
          )
          (
            D.reflow $ "The type `" ++ tipe ++ "` derives `" ++ member ++ "` here:"
          ,
            D.reflow $ "and its `where` block defines `" ++ member ++ "` too:"
          ,
            pickOne tipe member
          )

    Shadowed derived defined modul tipe member ->
      Report.Report "DERIVE SHADOWED" derived [] $
        Code.toPair source derived defined
          (
            D.reflow $ "The type `" ++ tipe ++ "` derives `" ++ member ++ "`, and the module `" ++ modul
              ++ "` also defines a function `" ++ member ++ "`."
          ,
            shadowHint modul tipe member
          )
          (
            D.reflow $ "The type `" ++ tipe ++ "` derives `" ++ member ++ "` here:"
          ,
            D.reflow $ "and the module `" ++ modul ++ "` defines a function `" ++ member ++ "` here:"
          ,
            shadowHint modul tipe member
          )

    Cannot region tipe member reason ->
      Report.Report "CANNOT DERIVE" region [] $
        Code.toSnippet source region Nothing
          (
            D.reflow $ "The type `" ++ tipe ++ "` cannot derive `" ++ member ++ "`:"
          ,
            reasonDoc tipe member reason
          )

    BesideEq derived written tipe member ->
      Report.Report "CANNOT DERIVE" derived [] $
        Code.toPair source derived written
          (
            D.reflow $ "The type `" ++ tipe ++ "` cannot derive `" ++ member ++ "`: it has its own `eq`."
          ,
            besideEqHint tipe member
          )
          (
            D.reflow $ "The type `" ++ tipe ++ "` derives `" ++ member ++ "` here:"
          ,
            D.reflow $ "but its `where` block defines its own `eq` here:"
          ,
            besideEqHint tipe member
          )

    NonEnumeration region tipe member ctor ->
      Report.Report "DERIVE ON NON-ENUMERATION" region [] $
        Code.toSnippet source region Nothing
          (
            D.reflow $ "The type `" ++ tipe ++ "` cannot derive `" ++ member ++ "`: the variant `" ++ ctor ++ "` has fields."
          ,
            D.reflow $
              "Only an enumeration (a type whose variants all have no fields, such as `type Color = Red | Green | Blue`)\
              \ can derive `minValue`, `maxValue`, `succ`, `pred` and `enumerate`. Write `" ++ tipe ++ "." ++ member
              ++ "` yourself in the `where` block if the type has a natural order of its values."
          )


reasonDoc :: String -> String -> Reason -> D.Doc
reasonDoc tipe member reason =
  case reason of
    Lacks path partType maybeCustom ->
      D.stack
        [ D.indent 4 $ D.dullyellow $ D.fromChars (path ++ " : " ++ partType)
        , D.reflow $ "This part has no `" ++ member ++ "`, and a derived `" ++ member ++ "` needs it in every part of the type."
        , D.toSimpleHint $
            case maybeCustom of
              Just custom ->
                "Derive or write `" ++ custom ++ "." ++ member ++ "`, or write `" ++ tipe ++ "." ++ member ++ "` yourself in the `where` block of `" ++ tipe ++ "`."
              Nothing ->
                "Write `" ++ tipe ++ "." ++ member ++ "` yourself in the `where` block of `" ++ tipe ++ "`."
        ]

    NotYet path partType what ->
      D.stack
        [ D.indent 4 $ D.dullyellow $ D.fromChars (path ++ " : " ++ partType)
        , D.reflow $ "This part has no `" ++ member ++ "` yet: " ++ what ++ "."
        , D.toSimpleHint $ "Write `" ++ tipe ++ "." ++ member ++ "` yourself in the `where` block of `" ++ tipe ++ "` for now."
        ]

    NonRegular use ->
      D.stack
        [ D.indent 4 $ D.dullyellow $ D.fromChars use
        , D.reflow $
            "The type is used at another argument inside itself. A derived function is compiled once for each type it is\
            \ used at, and this type would need infinitely many of them."
        , D.toSimpleHint $ "Write `" ++ tipe ++ "." ++ member ++ "` yourself in the `where` block of `" ++ tipe ++ "`."
        ]

    NonRegularGroup use used inside ->
      D.stack
        [ D.indent 4 $ D.dullyellow $ D.fromChars use
        , D.reflow $
            "`" ++ tipe ++ "` and `" ++ inside ++ "` refer to each other, and this use of `" ++ used ++ "` in a field of `" ++ inside
            ++ "` has other arguments than " ++ (if used == tipe then "the parameters of `" ++ tipe ++ "`" else "another use of `" ++ used ++ "` in them")
            ++ ", so the arguments keep growing. A derived function is compiled once for each type it is used at, and these\
            \ types would need infinitely many of them (the C generator does not support this)."
        , D.toSimpleHint $ "Write `" ++ tipe ++ "." ++ member ++ "` yourself in the `where` block of `" ++ tipe ++ "`."
        ]

    WrongShape path partType partMember written expected ->
      D.stack
        [ D.indent 4 $ D.dullyellow $ D.fromChars (path ++ " : " ++ partType)
        , D.reflow $ "A derived `" ++ member ++ "` calls `" ++ partMember ++ "` for this part, and it has this type:"
        , D.indent 4 $ D.dullyellow $ D.fromChars written
        , D.reflow $ "But a derived `" ++ member ++ "` needs it to have this type:"
        , D.indent 4 $ D.green $ D.fromChars expected
        , D.toSimpleHint $
            "Give `" ++ partMember ++ "` that type, or write `" ++ tipe ++ "." ++ member ++ "` yourself in the `where` block of `"
            ++ tipe ++ "`."
        ]

    NoParameter ->
      D.reflow $
        "`map` changes the last type parameter of a type (`map : (a -> b) -> Tree a -> Tree b`), and `" ++ tipe
        ++ "` has no type parameter."


besideEqHint :: String -> String -> D.Doc
besideEqHint tipe member =
  D.reflow $
    "A derived `" ++ member ++ "` looks at every part of the value and ignores `" ++ tipe ++ ".eq`, so two values that are equal\
    \ by your `eq` could " ++ (if member == "hash" then "get different hashes" else "compare as unequal")
    ++ ", and a `Dict`, a `Set` or a sort would go wrong. Write `" ++ tipe ++ "." ++ member
    ++ "` yourself in the `where` block, so that it agrees with `eq`."


pickOne :: String -> String -> D.Doc
pickOne tipe member =
  D.reflow $
    "Pick one: remove `" ++ member ++ "` from the `derive` line to keep your own `" ++ tipe ++ "." ++ member
    ++ "`, or remove your definition to get the derived one."


shadowHint :: String -> String -> String -> D.Doc
shadowHint modul tipe member =
  D.toSimpleHint $
    ( if lastPart modul == tipe
        then
          "Here `" ++ tipe ++ "." ++ member ++ "` would mean the function of the module, and the derived function would be\
          \ reachable only as `" ++ modul ++ "." ++ tipe ++ "." ++ member ++ "`."
        else
          "Two different functions named `" ++ member ++ "` in one module are a trap: `" ++ modul ++ "." ++ member
          ++ "` would be the function and `" ++ tipe ++ "." ++ member ++ "` the derived one."
    )
    ++ " Remove `" ++ member ++ "` from the module (or rename it): the derived function answers to `" ++ tipe ++ "." ++ member
    ++ "`, so calls written `" ++ tipe ++ "." ++ member ++ "` stay as they are."


lastPart :: String -> String
lastPart chars =
  reverse (takeWhile (/= '.') (reverse chars))


hint :: String -> D.Doc
hint member =
  case member of
    "decode" -> D.toSimpleHint "The derived decoder is named `decoder`, as the decoders of Elm programs usually are (`User.decoder`)."
    "eq" -> D.toSimpleHint "Equality (`==`) is structural for every type without a `derive` line; write `eq` yourself in the `where` block if the type needs another one."
    _ ->
      case Suggest.sort member id Derive.known of
        best : _ | Suggest.distance member best <= 3 -> D.toSimpleHint $ "Did you mean `" ++ best ++ "`?"
        _ -> D.reflow "Write the function yourself in the `where` block if the type needs it."


commas :: [String] -> String
commas names =
  List.intercalate ", " [ "`" ++ n ++ "`" | n <- names ]
