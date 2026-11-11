{-# LANGUAGE OverloadedStrings #-}
-- Problems found by the kind check of record extensions (Ficcus track D10).
-- See Canonicalize.Kind for the check itself.
module Reporting.Error.Kind
  ( Problem(..)
  , toReport
  )
  where


import qualified Data.List as List
import qualified Data.Map as Map

import qualified AST.Canonical as Can
import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeName as T
import qualified AST.Prim.TypeVar as T
import qualified Reporting.Annotation as A
import qualified Reporting.Doc as D
import qualified Reporting.Render.Code as Code
import qualified Reporting.Report as Report



-- PROBLEMS


data Problem
  = NotARecord (Maybe (T.Name, T.Var)) Can.Type
      -- ^ a record extension (`{ a | x : Int }`, directly or through the type alias and
      --   parameter given) whose extension is a type that is not a record
  | DuplicateFields (Maybe (T.Name, T.Var)) [(N.Name, Can.Type, Can.Type)]
      -- ^ a record extension that gives a field the extended record already has, with another type
  | UnmetConstraint T.Name T.Var Can.Type
      -- ^ a type that cannot satisfy the constraint of the type alias parameter (named `number`, `comparable`,
      --   `appendable` or `compappend`) it is given for



-- TO REPORT


toReport :: Code.Source -> A.Region -> Problem -> Report.Report
toReport source region problem =
  case problem of
    NotARecord maybeVia tipe ->
      Report.Report "BAD RECORD EXTENSION" region [] $
        Code.toSnippet source region Nothing
          (
            case maybeVia of
              Just (alias, param) ->
                D.reflow $
                  "The `" <> T.nameToChars alias <> "` type alias adds fields to its `" <> T.varToChars param
                  <> "` type variable, so I need a record there. But I see `" <> ppType tipe <> "`:"

              Nothing ->
                D.reflow $
                  "This record extension needs a record, but I see `" <> ppType tipe <> "`:"
          ,
            D.reflow $
              "Only a record type, or a type variable that stands for one, can be extended with more\
              \ fields. Is a type argument in the wrong place?"
          )

    DuplicateFields maybeVia clashes ->
      Report.Report "DUPLICATE FIELD" region [] $
        Code.toSnippet source region Nothing
          (
            D.reflow $
              case clashes of
                (name, _, _) : _ ->
                  "The `" <> N.toChars name <> "` field appears twice, with different types"
                  <> (case maybeVia of
                        Just (alias, param) -> " (the `" <> T.nameToChars alias <> "` type alias adds it to its `" <> T.varToChars param <> "` type variable):"
                        Nothing -> ":")
                [] -> "A field appears twice, with different types:"
          ,
            D.stack
              [ D.reflow $
                  case clashes of
                    (_, t1, t2) : _ -> "One has the type `" <> ppType t1 <> "` and the other `" <> ppType t2 <> "`."
                    [] -> ""
              , D.reflow "A record has one field of each name, so the two types must be the same. Change one of them!"
              ]
          )

    UnmetConstraint alias var tipe ->
      Report.Report "BAD TYPE ARGUMENT" region [] $
        Code.toSnippet source region Nothing
          (
            D.reflow $
              "The `" <> T.nameToChars alias <> "` type alias has a type variable named `" <> T.varToChars var
              <> "`, which only " <> constraintText var <> " can be, but I see `" <> ppType tipe <> "` there:"
          ,
            D.reflow $
              "Names that start with `number`, `comparable`, `appendable` and `compappend` stand for the constrained\
              \ type variables of the core libraries, in an alias as well. Give it a type that fits, or choose another\
              \ name for the type variable."
          )


constraintText :: T.Var -> String
constraintText (T.Var _ constraint) =
  case constraint of
    T.Number -> "an `Int` or a `Float`"
    T.Comparable -> "a comparable type (`Int`, `Float`, `Char`, `String`, or lists and tuples of them)"
    T.Appendable -> "a `String` or a `List`"
    T.CompAppend -> "a `String` or a `List` of comparable types"
    T.Any -> "any type"


-- A SMALL TYPE PRINTER (module names left out: the real names are in the source snippet)


ppType :: Can.Type -> String
ppType tipe =
  go False tipe
  where
    go paren t =
      case t of
        Can.TLambda a b -> wrap paren (go True a <> " -> " <> go False b)
        Can.TVar v -> T.varToChars v
        Can.TType _ name args -> app paren (T.nameToChars name) args
        Can.TAlias _ name args _ -> app paren (T.nameToChars name) (map snd args)
        Can.TUnit -> "()"
        Can.TPair a b -> "( " <> go False a <> ", " <> go False b <> " )"
        Can.TTriple a b c -> "( " <> go False a <> ", " <> go False b <> ", " <> go False c <> " )"
        Can.TRecord fields ext ->
          let
            fieldDoc (name, Can.FieldType _ ft) = N.toChars name <> " : " <> go False ft
            body = List.intercalate ", " (map fieldDoc (Map.toList fields))
          in
          case ext of
            Nothing | Map.null fields -> "{}"
            Nothing -> "{ " <> body <> " }"
            Just v -> "{ " <> T.varToChars v <> " | " <> body <> " }"

    app paren name args =
      case args of
        [] -> name
        _ -> wrap paren (unwords (name : map (go True) args))

    wrap paren s =
      if paren then "(" <> s <> ")" else s
