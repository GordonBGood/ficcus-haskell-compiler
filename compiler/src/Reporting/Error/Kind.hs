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
  | DuplicateFields (Maybe (T.Name, T.Var)) [N.Name]
      -- ^ a record extension that gives fields the extended record already has



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

    DuplicateFields maybeVia names ->
      Report.Report "DUPLICATE FIELD" region [] $
        Code.toSnippet source region Nothing
          (
            D.reflow $
              case maybeVia of
                Just (alias, param) ->
                  "The `" <> T.nameToChars alias <> "` type alias adds " <> fieldsText names
                  <> " to its `" <> T.varToChars param <> "` type variable, but the record I find there already has "
                  <> (if length names == 1 then "it:" else "them:")

                Nothing ->
                  "This record extension adds " <> fieldsText names <> " that the extended record already has:"
          ,
            D.reflow "A record cannot have two fields with the same name. Remove the field from one of the two types!"
          )


fieldsText :: [N.Name] -> String
fieldsText names =
  case names of
    [name] -> "a `" <> N.toChars name <> "` field"
    _ -> "the " <> List.intercalate ", " (map (\n -> "`" <> N.toChars n <> "`") names) <> " fields"



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
