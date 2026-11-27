{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE OverloadedStrings #-}
module Reporting.Error.Type
  ( Error(..)
  , MemberOwner(..)
  , Annotated(..)
  -- expectations
  , Expected(..)
  , Context(..)
  , SubContext(..)
  , MaybeName(..)
  , Category(..)
  , PExpected(..)
  , PContext(..)
  , PCategory(..)
  , typeReplace
  , ptypeReplace
  -- make reports
  , toReport
  )
  where


import Prelude hiding (round)
import qualified Data.List as List
import qualified Data.Map as Map

import qualified AST.Canonical as Can
import qualified AST.Members as Members
import qualified AST.Prim.Name as N
import qualified AST.Prim.Operator as Op
import qualified AST.Prim.TypeName as T
import qualified AST.Prim.TypeVar as T (Var, varToChars)
import qualified Data.Index as Index
import qualified Reporting.Annotation as A
import qualified Reporting.Doc as D
import qualified Reporting.Render.Code as Code
import qualified Reporting.Render.Type as RT
import qualified Reporting.Render.Type.Localizer as L
import qualified Reporting.Report as Report
import qualified Reporting.Suggest as Suggest
import qualified Type.Error as T



-- ERRORS


data Error
  = BadExpr A.Region Category T.Type (Expected T.Type)
  | BadPattern A.Region PCategory T.Type (PExpected T.Type)
  | InfiniteType A.Region N.Name T.Type
  | RigidEscape A.Region N.Name String  -- annotated definition, type variable of its annotation
  | Runaway A.Region Bool               -- unification does not terminate; True: an infinite type
  | HiddenCycle A.Region N.Name         -- a cyclic type among the variables of a definition, not in its own type
  -- Ficcus (ATTACH A2): the constrained function that was used, the member it needs
  -- (A5c: the texts speak of attached functions and `has`, docs/A5-INFERENCE-DESIGN.md section 4.)  The function is the name
  -- of the use: a function, an operator (`/`), `<Float literal>`, or a selector (`zero$selector`, a bare attached name).
  | NoMember A.Region N.Name T.Type [N.Name] Bool [(N.Name, T.Type)]   -- the type, the members it has, is it a built-in type, the members needed
  | BadMember A.Region N.Name N.Name MemberOwner T.Type T.Type    -- the type the member has, the type needed
  | MemberNeedsSignature A.Region N.Name N.Name String            -- the type whose member has no signature
  | MissingConstraint A.Region N.Name String [(N.Name, T.Type)] (Maybe Annotated) [String]   -- the type variable, the members needed, the annotated definition, the types in sight that have them
  | MissingSignature A.Region N.Name N.Name T.Type [(String, [(N.Name, T.Type)])]   -- (a value, the monomorphism restriction) the function used, the definition, its type, the requirements by variable
  | UnknownMemberType A.Region N.Name (Maybe String) [(N.Name, T.Type)] [String] (Maybe N.Name)   -- the kind of the variable (number, comparable, ...), the members needed, the types in sight that have them, the value whose type it is
  -- Ficcus (ATTACH A3): a well known member (`add`, `compare`, ...) that has not the type the language needs
  | WellKnownShape A.Region String N.Name String        -- the type, the member, the type the member must have
  | WellKnownNoSignature A.Region String N.Name String  -- the same, for a member without a type annotation
  | WithNotes Error [String]                             -- an error with more to say about the members of the types in it


data MemberOwner
  = MemberOfType String         -- the member of a custom type
  | MemberOfVariable String     -- the `where` line of the enclosing signature on this type variable
  | MemberOfOtherUse String A.Region   -- (A5c) another use in the same definition needs the member of this variable at another type


-- | (A5c) the annotated definition whose `where` block lacks a line: its name, its type (without the `where` lines),
-- the `where` lines it has, and whether it is at the top level
data Annotated =
  Annotated N.Name T.Type [(String, N.Name, T.Type)] Bool   -- True: at the top level (a `let` definition cannot have `where`)



-- EXPRESSION EXPECTATIONS


data Expected tipe
  = NoExpectation tipe
  | FromContext A.Region Context tipe
  | FromAnnotation N.Name Int SubContext tipe


data Context
  = ListEntry Index.ZeroBased
  | Negate
  | OpLeft Op.Name
  | OpRight Op.Name
  | IfCondition
  | IfBranch Index.ZeroBased
  | CaseBranch Index.ZeroBased
  | CallArity MaybeName Int
  | CallArg MaybeName Index.ZeroBased
  | RecordAccess A.Region (Maybe N.Name) A.Region N.Name
  | RecordUpdateKeys N.Name (Map.Map N.Name Can.FieldUpdate)
  | RecordUpdateValue N.Name
  | Destructure


data SubContext
  = TypedIfBranch Index.ZeroBased
  | TypedCaseBranch Index.ZeroBased
  | TypedBody


data MaybeName
  = FuncName N.Name
  | CtorName N.Name
  | OpName Op.Name
  | NoName


data Category
  = List
  | Number
  | Float
  | String
  | Char
  | If
  | Case
  | CallResult MaybeName
  | Lambda
  | Accessor N.Name
  | Access N.Name
  | Record
  | Tuple
  | Unit
  | Shader
  | Effects
  | Local N.Name
  | Foreign N.Name
  | Operator Op.Name



-- PATTERN EXPECTATIONS


data PExpected tipe
  = PNoExpectation tipe
  | PFromContext A.Region PContext tipe


data PContext
  = PTypedArg N.Name Index.ZeroBased
  | PCaseMatch Index.ZeroBased
  | PCtorArg N.Name Index.ZeroBased
  | PListEntry Index.ZeroBased
  | PTail


data PCategory
  = PRecord
  | PUnit
  | PTuple
  | PList
  | PCtor N.Name
  | PInt
  | PStr
  | PChr
  | PBool



-- HELPERS


typeReplace :: Expected a -> b -> Expected b
typeReplace expectation tipe =
  case expectation of
    NoExpectation _ ->
      NoExpectation tipe

    FromContext region context _ ->
      FromContext region context tipe

    FromAnnotation name arity context _ ->
      FromAnnotation name arity context tipe


ptypeReplace :: PExpected a -> b -> PExpected b
ptypeReplace expectation tipe =
  case expectation of
    PNoExpectation _ ->
      PNoExpectation tipe

    PFromContext region context _ ->
      PFromContext region context tipe



-- TO REPORT


toReport :: Code.Source -> L.Localizer -> Error -> Report.Report
toReport source localizer err =
  case err of
    WithNotes inner notes ->
      case toReport source localizer inner of
        Report.Report title region suggestions message ->
          Report.Report title region suggestions (D.stack (message : map D.reflow notes))

    BadExpr region category actualType expected ->
      toExprReport source localizer region category actualType expected

    BadPattern region category tipe expected ->
      toPatternReport source localizer region category tipe expected

    InfiniteType region name overallType ->
      toInfiniteReport source localizer region name overallType

    RigidEscape region name var ->
      toRigidEscapeReport source region name var

    Runaway region isCycle ->
      toRunawayReport source region isCycle

    NoMember region function tipe members builtin needed ->
      let
        use = useOf function
        t = typeLine localizer tipe
        hasPart
          | builtin = "`" <> t <> "` does not have " <> oneOrThem needed <> "."
          | null members = "`" <> t <> "` has no attached functions that I can see here."
          | otherwise = "`" <> t <> "` has only " <> codeList (map N.toChars members) <> "."
        first =
          case use of
            UseLiteral -> "This Float literal is used as a `" <> t <> "`, so `" <> t <> "` needs an attached `fromFloat` function, but " <> hasPart
            UseOperator op | builtin -> "The (" <> op <> ") operator needs a type that has " <> functionsWords needed <> ", and `" <> t <> "` does not have " <> oneOrThem needed <> "."
            _ -> useSubject use <> " needs `" <> t <> "` to have " <> functionsWords needed <> ", but " <> hasPart
        names = map (N.toChars . fst) needed
        advice
          | builtin, t == "Int", names == ["div"] = [ D.reflow "Use (//) for integers, or `toFloat` first." ]
          | builtin, t == "Float", names `elem` [["idiv"], ["mod"], ["rem"]] = [ D.reflow "Use (/) for Float, or `round` first." ]
          -- (A4bf, review F1) an extensible record (Type.OpenRecord): the built-in note would say that records have `compare`
          | builtin, T.Record _ ext <- tipe, isOpenExt ext = [ D.reflow (openRecordNote needed) ]
          | builtin = [ D.reflow builtinNote ]
          | otherwise =
              [ D.reflow $ "Add " <> itOrThem needed <> " to the `where` block of `" <> t <> "`"
                  <> (if null members then " (a module that defines `" <> t <> "` must expose the type for its attached functions to be seen):" else ":")
              , memberLines localizer Nothing needed
              ]
      in
      Report.Report "NO ATTACHED FUNCTION" region [] $
        Code.toSnippet source region Nothing (D.reflow first, D.stack advice)

    BadMember region function member owner actual needed ->
      Report.Report "ATTACHED FUNCTION MISMATCH" region [] $
        Code.toSnippet source region Nothing
          (
            D.reflow $
              case (useOf function, owner) of
                (UseSelector _, MemberOfOtherUse var _) -> "`" <> N.toChars member <> "` here needs `" <> var <> "` to have it with this type:"
                (UseSelector _, _) -> "`" <> N.toChars member <> "` here is used with this type:"
                (use, MemberOfOtherUse var _) -> useSubject use <> " needs `" <> var <> "` to have an attached `" <> N.toChars member <> "` function with this type:"
                (use, _) -> useSubject use <> " needs the attached `" <> N.toChars member <> "` function with this type:"
          ,
            D.stack $
              [ D.indent 4 $ D.green $ T.toDoc localizer RT.None needed
              , D.reflow $
                  case owner of
                    MemberOfType tipe ->
                      "But `" <> tipe <> "." <> N.toChars member <> "` has this type:"
                    MemberOfVariable var ->
                      "But the line `" <> var <> " has " <> N.toChars member <> "` in the `where` block of the type annotation says:"
                    MemberOfOtherUse _ other ->
                      "But another use, on line " <> show (lineOf other) <> ", needs it with this type:"
              , D.indent 4 $ D.dullyellow $ T.toDoc localizer RT.None actual
              ] ++
              [ D.reflow $
                  "A type has one attached function of each name, so `" <> var <> "` cannot have both. Make the two uses agree,\
                  \ or write the type's name in front of `" <> N.toChars member <> "` at one of them."
              | MemberOfOtherUse var _ <- [owner]
              ]
          )

    WellKnownShape region tipe member expected ->
      Report.Report "OPERATOR FUNCTION WITH THE WRONG TYPE" region [] $
        Code.toSnippet source region Nothing
          (
            D.reflow $
              "The operators use `" <> tipe <> "." <> N.toChars member <> "` (for example `+` uses `add`, `<` uses `compare`),\
              \ so it must have exactly this type:"
          ,
            D.stack
              [ D.indent 4 $ D.green $ D.fromChars (N.toChars member <> " : " <> expected)
              , D.reflow $
                  "If this function is not meant for the operators, give it another name."
              ]
          )

    WellKnownNoSignature region tipe member expected ->
      Report.Report "OPERATOR FUNCTION WITHOUT TYPE ANNOTATION" region [] $
        Code.toSnippet source region Nothing
          (
            D.reflow $
              "The operators use `" <> tipe <> "." <> N.toChars member <> "` (for example `+` uses `add`, `<` uses `compare`),\
              \ so it needs a type annotation, and it must be exactly this one:"
          ,
            D.stack
              [ D.indent 4 $ D.green $ D.fromChars (N.toChars member <> " : " <> expected)
              , D.reflow $
                  "If this function is not meant for the operators, give it another name."
              ]
          )

    MemberNeedsSignature region function member tipe ->
      Report.Report "ATTACHED FUNCTION WITHOUT TYPE ANNOTATION" region [] $
        Code.toSnippet source region Nothing
          (
            D.reflow $
              useSubject (useOf function) <> " needs `" <> tipe <> "." <> N.toChars member
              <> "`, which is defined in this module without a type annotation."
          ,
            D.reflow $
              "I check the uses of an attached function by its type annotation. Add one to `" <> N.toChars member
              <> "` in the `where` block of `" <> tipe <> "`."
          )

    MissingConstraint region function var needed annotated owners ->
      let
        use = useOf function
        first =
          case use of
            UseSelector m -> "`" <> m <> "` here is an attached function of `" <> var <> "`:"
            _ -> useSubject use <> " needs `" <> var <> "` to have " <> functionsWords needed <> ":"
        newLines = [ D.green (D.fromChars var <> " has " <> D.fromName member <> " : " <> T.toDoc localizer RT.None tipe) | (member, tipe) <- needed ]
        lineWord = case needed of { [_] -> "this line"; _ -> "these lines" }
        suggestion =
          case annotated of
            Just (Annotated name defType wheres True) ->
              [ D.reflow $ "But the type annotation of `" <> Members.displayName name <> "` does not say that `" <> var <> "` has "
                  <> oneOrThem needed <> ". Add " <> lineWord <> " under it:"
              , D.indent 4 $ D.vcat $
                  [ D.dullyellow (D.fromName name <> " : " <> T.toDoc localizer RT.None defType)
                  , D.indent 4 $ D.cyan "where"
                  ] ++
                  [ D.indent 8 (D.fromChars v <> " has " <> D.fromName m <> " : " <> T.toDoc localizer RT.None t) | (v, m, t) <- wheres ] ++
                  map (D.indent 8) newLines
              , D.reflow "Or remove the type annotation: I can work out the `where` lines myself."
              ]
            Just (Annotated name _ _ False) ->
              [ D.reflow $ "But the type annotation of `" <> Members.displayName name <> "` does not say that `" <> var <> "` has "
                  <> oneOrThem needed <> ", and a `let` definition cannot have a `where` block. Remove the type annotation:\
                  \ I work out the `where` lines of `let` definitions myself."
              ]
            Nothing ->
              [ D.reflow $ "But the type annotation does not say that `" <> var <> "` has " <> oneOrThem needed <> ". Add " <> lineWord
                  <> " to its `where` block:"
              , D.indent 4 (D.vcat newLines)
              ]
        hint =
          case (use, owners) of
            (UseSelector m, [one]) -> [ D.reflow $ "If you mean the one of `" <> one <> "`, write `" <> one <> "." <> m <> "`." ]
            _ -> []
      in
      Report.Report "INCOMPLETE TYPE ANNOTATION" region [] $
        Code.toSnippet source region Nothing (D.reflow first, D.stack (suggestion ++ hint))

    MissingSignature region function name defType constraints ->
      Report.Report "INCOMPLETE TYPE ANNOTATION" region [] $
        Code.toSnippet source region Nothing
          (
            D.reflow $
              "`" <> Members.displayName name <> "` is a value, not a function, so I give it one type. "
              <> (case useOf function of
                    UseSelector m -> "The attached `" <> m <> "` function in it"
                    UseOperator op -> "The (" <> op <> ") operator in it"
                    UseLiteral -> "A Float literal in it"
                    UseCall f -> "Its `" <> f <> "` call")
              <> " needs that type to have " <> functionsWords [ e | (_, entries) <- constraints, e <- entries ]
              <> ", and nothing here says which type it is:"
          ,
            D.stack
              [ D.reflow "Add a type annotation that says it:"
              , D.indent 4 $ D.vcat $
                  [ D.dullyellow (D.fromName name <> " : " <> T.toDoc localizer RT.None defType)
                  , D.indent 4 $ D.cyan "where"
                  ] ++
                  [ D.indent 8 $ D.green (D.fromChars var <> " has " <> D.fromName member <> " : " <> T.toDoc localizer RT.None tipe)
                  | (var, entries) <- constraints, (member, tipe) <- entries
                  ]
              , D.reflow $
                  "Or make `" <> Members.displayName name <> "` a function by giving it its arguments: I work out the `where`\
                  \ lines of functions myself."
              ]
          )

    UnknownMemberType region function kind needed owners valueName ->
      let
        use = useOf function
        first =
          case use of
            UseSelector m -> "I cannot tell which type's `" <> m <> "` to use here:"
            UseLiteral -> "I cannot tell which type this Float literal is. It needs a type with an attached `fromFloat` function:"
            _ -> useSubject use <> " needs a type with " <> functionsWords needed <> ", but I cannot tell which type:"
        ownersSentence =
          case owners of
            [] -> []
            _ -> [ D.reflow $ codeList owners <> " " <> (case owners of { [_] -> "has "; _ -> "have " })
                     <> (case needed of { [_] -> functionsWords needed; _ -> "them" }) <> "." ]
        settle =
          case kind of
            Just "number" ->
              [ D.reflow $
                  "Only a number literal gives the type, and `Int` and `Float` do not have " <> oneOrThem needed
                  <> ". Write a value of the type you mean instead of the literal"
                  <> (case owners of { one : _ -> ", for example a `" <> one <> "` value."; [] -> "." })
              ]
            Just k ->
              D.reflow ("The type is only known to be `" <> k <> "`, which does not say which type it is. Add a type annotation that names it.")
                : ownersSentence
            Nothing ->
              case (valueName, owners) of
                (Just name, one : _) ->
                  [ D.reflow "Nothing around it settles the type. Add a type annotation that names it, for example:"
                  , D.indent 4 $ D.dullyellow $ D.fromName name <> " : " <> D.fromChars one
                  ] ++ ownersSentence
                _ ->
                  D.reflow "Nothing around it settles the type. Add a type annotation that names it." : ownersSentence
      in
      Report.Report "AMBIGUOUS TYPE" region [] $
        Code.toSnippet source region Nothing (D.reflow first, D.stack settle)

    HiddenCycle region name ->
      Report.Report "INFINITE TYPE" region [] $
        Code.toSnippet source region Nothing
          (
            D.reflow $
              "While checking `" <> Members.displayName name <> "`, I found a type that would have to contain itself:"
          ,
            D.stack
              [ D.reflow $
                  "It is not part of the type of `" <> Members.displayName name <> "`, so I cannot show it, but somewhere in this definition a type variable ends up equal to a type that contains that same variable, like `m` and `OnePlus m` at once. There is no finite type that fits."
              , D.toSimpleHint
                  "Phantom types are a common source of this. Check the types of the values that are\
                  \ compared or combined here."
              ]
          )



-- Ficcus (ATTACH A2; A5c texts; A4b: `hash`, the containers)
openRecordNote :: [(N.Name, T.Type)] -> String
openRecordNote needed =
  "Only a closed record (such as `{ x : Int, y : Int }`) has " <> them <> ". This type is an extensible record (`{ r | ... }`),\
  \ which may hold more fields that do not have " <> them <> ", such as functions. The type must be a closed record: write all\
  \ its fields in the type annotation."
  where
    them = List.intercalate " and " [ "`" <> N.toChars m <> "`" | (m, _) <- needed ]


isOpenExt :: T.Extension -> Bool
isOpenExt ext =
  case ext of
    T.Closed -> False
    _ -> True


builtinNote :: String
builtinNote =
  "`Int`, `Float`, `String`, `Char`, `List` and tuples have only the attached functions that the language gives them, as far\
  \ as their type allows (`add`, `sub`, `mul`, `pow`, `neg`, `abs`, `fromInt`, `fromFloat`, `zero`, `div`, `idiv`, `mod`, `rem`,\
  \ `compare`, `eq`, `hash`, `append`); records, `Maybe`, `Result`, `Array`, `Vector`, `Dict` and `Set` have `compare` and `hash`\
  \ when their parts do, in a module that sees a type with attached functions. Any other attached function can only come from a custom type that defines or derives it in its `where` block."


-- | (A5c) how a use is named in a message: a call of a function, an operator, a Float literal, or a bare attached name
data Use
  = UseCall String
  | UseOperator String
  | UseLiteral
  | UseSelector String


useOf :: N.Name -> Use
useOf function =
  case N.toChars function of
    "<Float literal>" -> UseLiteral
    chars
      | Just m <- List.stripPrefix (reverse "$selector") (reverse chars) -> UseSelector (reverse m)
      | all (`elem` ("+-*/<>=|&^%!.:" :: String)) chars -> UseOperator chars
      | otherwise -> UseCall (Members.displayName function)


-- "This `sum` call", "The (/) operator", "This Float literal", "`zero` here"
useSubject :: Use -> String
useSubject use =
  case use of
    UseCall f -> "This `" <> f <> "` call"
    UseOperator op -> "The (" <> op <> ") operator"
    UseLiteral -> "This Float literal"
    UseSelector m -> "`" <> m <> "` here"


-- "an attached `add` function", "attached `add` and `zero` functions"
functionsWords :: [(N.Name, a)] -> String
functionsWords needed =
  case map (\(member, _) -> N.toChars member) needed of
    [one] -> "an attached `" <> one <> "` function"
    names -> "attached " <> codeList names <> " functions"


oneOrThem :: [a] -> String
oneOrThem needed =
  case needed of
    [_] -> "one"
    _ -> "them"


itOrThem :: [a] -> String
itOrThem needed =
  case needed of
    [_] -> "it"
    _ -> "them"


-- "`a`", "`a` and `b`", "`a`, `b` and `c`"
codeList :: [String] -> String
codeList names =
  case map (\n -> "`" <> n <> "`") names of
    [] -> ""
    [one] -> one
    quoted -> List.intercalate ", " (init quoted) <> " and " <> last quoted


typeLine :: L.Localizer -> T.Type -> String
typeLine localizer tipe =
  D.toLine (T.toDoc localizer RT.None tipe)


lineOf :: A.Region -> Int
lineOf =
  A.startLine


-- the lines `zero : T` or, with a variable, `a has zero : T`
memberLines :: L.Localizer -> Maybe String -> [(N.Name, T.Type)] -> D.Doc
memberLines localizer maybeVar needed =
  D.indent 4 $ D.vcat
    [ D.green $ maybe "" (\var -> D.fromChars var <> " has ") maybeVar <> D.fromName member <> " : " <> T.toDoc localizer RT.None tipe
    | (member, tipe) <- needed
    ]



-- TO PATTERN REPORT


toPatternReport :: Code.Source -> L.Localizer -> A.Region -> PCategory -> T.Type -> PExpected T.Type -> Report.Report
toPatternReport source localizer patternRegion category tipe expected =
  Report.Report "TYPE MISMATCH" patternRegion [] $
  case expected of
    PNoExpectation expectedType ->
      Code.toSnippet source patternRegion Nothing $
        ( "This pattern is being used in an unexpected way:"
        , patternTypeComparison localizer tipe expectedType
            (addPatternCategory "It is" category)
            "But it needs to match:"
            []
        )

    PFromContext region context expectedType ->
      Code.toSnippet source region (Just patternRegion) $
        case context of
          PTypedArg name index ->
            ( D.reflow $
                "The " <> D.ordinal index <> " argument to `" <> Members.displayName name <> "` is weird."
            , patternTypeComparison localizer tipe expectedType
                (addPatternCategory "The argument is a pattern that matches" category)
                ( "But the type annotation on `" <> Members.displayName name
                  <> "` says the " <> D.ordinal index <> " argument should be:"
                )
                []
            )

          PCaseMatch index ->
            if index == Index.first then
              (
                D.reflow $
                  "The 1st pattern in this `case` causing a mismatch:"
              ,
                patternTypeComparison localizer tipe expectedType
                  (addPatternCategory "The first pattern is trying to match" category)
                  "But the expression between `case` and `of` is:"
                  [ D.reflow $
                      "These can never match! Is the pattern the problem? Or is it the expression?"
                  ]
              )
            else
              ( D.reflow $
                  "The " <> D.ordinal index <> " pattern in this `case` does not match the previous ones."
              , patternTypeComparison localizer tipe expectedType
                  (addPatternCategory ("The " <> D.ordinal index <> " pattern is trying to match") category)
                  "But all the previous patterns match:"
                  [ D.link "Note"
                      "A `case` expression can only handle one type of value, so you may want to use"
                      "custom-types"
                      "to handle “mixing” types."
                  ]
              )

          PCtorArg name index ->
            ( D.reflow $
                "The " <> D.ordinal index <> " argument to `" <> Members.displayName name <> "` is weird."
            , patternTypeComparison localizer tipe expectedType
                (addPatternCategory "It is trying to match" category)
                ( "But `" <> Members.displayName name <> "` needs its "
                  <> D.ordinal index <> " argument to be:"
                )
                []
            )

          PListEntry index ->
            ( D.reflow $
                "The " <> D.ordinal index <> " pattern in this list does not match all the previous ones:"
            , patternTypeComparison localizer tipe expectedType
                (addPatternCategory ("The " <> D.ordinal index <> " pattern is trying to match") category)
                "But all the previous patterns in the list are:"
                [ D.link "Hint"
                    "Everything in a list must be the same type of value. This way, we never\
                    \ run into unexpected values partway through a List.map, List.foldl, etc. Read"
                    "custom-types"
                    "to learn how to “mix” types."
                ]
            )

          PTail ->
            ( D.reflow $
                "The pattern after (::) is causing issues."
            , patternTypeComparison localizer tipe expectedType
                (addPatternCategory "The pattern after (::) is trying to match" category)
                "But it needs to match lists like this:"
                []
            )



-- PATTERN HELPERS


patternTypeComparison :: L.Localizer -> T.Type -> T.Type -> String -> String -> [D.Doc] -> D.Doc
patternTypeComparison localizer actual expected iAmSeeing insteadOf contextHints =
  let
    (actualDoc, expectedDoc, problems) =
      T.toComparison localizer actual expected
  in
  D.stack $
    [ D.reflow iAmSeeing
    , D.indent 4 actualDoc
    , D.reflow insteadOf
    , D.indent 4 expectedDoc
    ]
    ++ problemsToHint problems
    ++ contextHints


addPatternCategory :: String -> PCategory -> String
addPatternCategory iAmTryingToMatch category =
  iAmTryingToMatch <>
    case category of
      PRecord -> " record values of type:"
      PUnit -> " unit values:"
      PTuple -> " tuples of type:"
      PList -> " lists of type:"
      PCtor name -> " `" <> Members.displayName name <> "` values of type:"
      PInt -> " integers:"
      PStr -> " strings:"
      PChr -> " characters:"
      PBool -> " booleans:"



-- EXPR HELPERS


typeComparison :: L.Localizer -> T.Type -> T.Type -> String -> String -> [D.Doc] -> D.Doc
typeComparison localizer actual expected iAmSeeing insteadOf contextHints =
  let
    (actualDoc, expectedDoc, problems) =
      T.toComparison localizer actual expected
  in
  D.stack $
    [ D.reflow iAmSeeing
    , D.indent 4 actualDoc
    , D.reflow insteadOf
    , D.indent 4 expectedDoc
    ]
    ++ contextHints
    ++ problemsToHint problems


loneType :: L.Localizer -> T.Type -> T.Type -> D.Doc -> [D.Doc] -> D.Doc
loneType localizer actual expected iAmSeeing furtherDetails =
  let
    (actualDoc, _, problems) =
      T.toComparison localizer actual expected
  in
  D.stack $
    [ iAmSeeing
    , D.indent 4 actualDoc
    ]
    ++ furtherDetails
    ++ problemsToHint problems


addCategory :: String -> Category -> String
addCategory thisIs category =
  case category of
    Local n      -> "This `" <> Members.displayName n <> "` value is a:"
    Foreign n    -> "This `" <> Members.displayName n <> "` value is a:"
    Operator op  -> "This (" <> Op.toChars op <> ") operator is a:"
    Access f     -> "The value at ." <> Members.displayName f <> " is a:"
    Accessor f   -> "This ." <> Members.displayName f <> " field access function has type:"
    If           -> "This `if` expression produces:"
    Case         -> "This `case` expression produces:"
    List         -> thisIs <> " a list of type:"
    Number       -> thisIs <> " a number of type:"
    Float        -> thisIs <> " a float of type:"
    String       -> thisIs <> " a string of type:"
    Char         -> thisIs <> " a character of type:"
    Lambda       -> thisIs <> " an anonymous function of type:"
    Record       -> thisIs <> " a record of type:"
    Tuple        -> thisIs <> " a tuple of type:"
    Unit         -> thisIs <> " a unit value:"
    Shader       -> thisIs <> " a GLSL shader of type:"
    Effects      -> thisIs <> " a thing for CORE LIBRARIES ONLY."
    CallResult m ->
      case m of
        NoName     -> thisIs <> ":"
        FuncName n -> "This `" <> Members.displayName n <> "` call produces:"
        CtorName n -> "This `" <> Members.displayName n <> "` call produces:"
        OpName   _ -> thisIs <> ":"


problemsToHint :: [T.Problem] -> [D.Doc]
problemsToHint problems =
  case problems of
    [] ->
      []

    problem : _ ->
      problemToHint problem


problemToHint :: T.Problem -> [D.Doc]
problemToHint problem =
  case problem of
    T.IntFloat ->
      [ D.fancyLink "Note" ["Read"] "implicit-casts"
          ["to","learn","why","Elm","does","not","implicitly","convert"
          ,"Ints","to","Floats.","Use",D.green "toFloat","and"
          ,D.green "round","to","do","explicit","conversions."
          ]
      ]

    T.StringFromInt ->
      [ D.toFancyHint
          ["Want","to","convert","an","Int","into","a","String?"
          ,"Use","the",D.green "String.fromInt","function!"
          ]
      ]

    T.StringFromFloat ->
      [ D.toFancyHint
          ["Want","to","convert","a","Float","into","a","String?"
          ,"Use","the",D.green "String.fromFloat","function!"
          ]
      ]

    T.StringToInt ->
      [ D.toFancyHint
          ["Want","to","convert","a","String","into","an","Int?"
          ,"Use","the",D.green "String.toInt","function!"
          ]
      ]

    T.StringToFloat ->
      [ D.toFancyHint
          ["Want","to","convert","a","String","into","a","Float?"
          ,"Use","the",D.green "String.toFloat","function!"
          ]
      ]

    T.AnythingToBool ->
      [ D.toSimpleHint $
          "Elm does not have “truthiness” such that ints and strings and lists\
          \ are automatically converted to booleans. Do that conversion explicitly!"
      ]

    T.AnythingFromMaybe ->
      [ D.toFancyHint
          ["Use",D.green "Maybe.withDefault","to","handle","possible","errors."
          ,"Longer","term,","it","is","usually","better","to","write","out","the"
          ,"full","`case`","though!"
          ]
      ]

    T.ArityMismatch x y ->
      [ D.toSimpleHint $
          if x < y then
            "It looks like it takes too few arguments. I was expecting " ++ show (y - x) ++ " more."
          else
            "It looks like it takes too many arguments. I see " ++ show (x - y) ++ " extra."
      ]

    T.BadFlexSuper direction super _ tipe ->
      case tipe of
        T.Lambda _ _ _   -> badFlexSuper direction super tipe
        T.Infinite       -> []
        T.Error          -> []
        T.FlexVar _      -> []
        T.FlexSuper s _  -> badFlexFlexSuper super s
        T.RigidVar y     -> badRigidVar y (toASuperThing super)
        T.RigidSuper s _ -> badRigidSuper s (toASuperThing super)
        T.Type _ _ _     -> badFlexSuper direction super tipe
        T.Record _ _     -> badFlexSuper direction super tipe
        T.Unit           -> badFlexSuper direction super tipe
        T.Pair _ _       -> badFlexSuper direction super tipe
        T.Triple _ _ _   -> badFlexSuper direction super tipe
        T.Alias _ _ _ _  -> badFlexSuper direction super tipe

    T.BadRigidVar x tipe ->
      case tipe of
        T.Lambda _ _ _   -> badRigidVar x "a function"
        T.Infinite       -> []
        T.Error          -> []
        T.FlexVar _      -> []
        T.FlexSuper s _  -> badRigidVar x (toASuperThing s)
        T.RigidVar y     -> badDoubleRigid x y
        T.RigidSuper _ y -> badDoubleRigid x y
        T.Type _ n _     -> badRigidVar x ("a `" ++ T.nameToChars n ++ "` value")
        T.Record _ _     -> badRigidVar x "a record"
        T.Unit           -> badRigidVar x "a unit value"
        T.Pair _ _       -> badRigidVar x "a tuple"
        T.Triple _ _ _   -> badRigidVar x "a tuple"
        T.Alias _ n _ _  -> badRigidVar x ("a `" ++ T.nameToChars n ++ "` value")

    T.BadRigidSuper super x tipe ->
      case tipe of
        T.Lambda _ _ _   -> badRigidSuper super "a function"
        T.Infinite       -> []
        T.Error          -> []
        T.FlexVar _      -> []
        T.FlexSuper s _  -> badRigidSuper super (toASuperThing s)
        T.RigidVar y     -> badDoubleRigid x y
        T.RigidSuper _ y -> badDoubleRigid x y
        T.Type _ n _     -> badRigidSuper super ("a `" ++ T.nameToChars n ++ "` value")
        T.Record _ _     -> badRigidSuper super "a record"
        T.Unit           -> badRigidSuper super "a unit value"
        T.Pair _ _       -> badRigidSuper super "a tuple"
        T.Triple _ _ _   -> badRigidSuper super "a tuple"
        T.Alias _ n _ _  -> badRigidSuper super ("a `" ++ T.nameToChars n ++ "` value")

    T.FieldsMissing fields ->
      case map (D.green . D.fromName) fields of
        [] ->
          []

        [f1] ->
          [ D.toFancyHint ["Looks","like","the",f1,"field","is","missing."]
          ]

        fieldDocs ->
          [ D.toFancyHint $
              ["Looks","like","fields"] ++ D.commaSep "and" id fieldDocs ++ ["are","missing."]
          ]


    T.FieldTypo typo possibilities ->
      case Suggest.sort (Members.displayName typo) Members.displayName possibilities of
        [] ->
          []

        nearest:_ ->
          [ D.toFancyHint $
              ["Seems","like","a","record","field","typo.","Maybe"
              ,D.dullyellow (D.fromName typo),"should","be"
              ,D.green (D.fromName nearest) <> "?"
              ]
          , D.toSimpleHint
              "Can more type annotations be added? Type annotations always help me give\
              \ more specific messages, and I think they could help a lot in this case!"
          ]



-- BAD RIGID HINTS


badRigidVar :: T.Var -> String -> [D.Doc]
badRigidVar name aThing =
  [ D.toSimpleHint $
      "Your type annotation uses type variable `" ++ T.varToChars name ++
      "` which means ANY type of value can flow through, but your code is saying it specifically wants "
      ++ aThing ++ ". Maybe change your type annotation to\
      \ be more specific? Maybe change the code to be more general?"
  , D.reflowLink "Read" "type-annotations" "for more advice!"
  ]


badDoubleRigid :: T.Var -> T.Var -> [D.Doc]
badDoubleRigid x y =
  [ D.toSimpleHint $
      "Your type annotation uses `" ++ T.varToChars x ++ "` and `" ++ T.varToChars y ++
      "` as separate type variables. Your code seems to be saying they are the\
      \ same though. Maybe they should be the same in your type annotation?\
      \ Maybe your code uses them in a weird way?"
  , D.reflowLink "Read" "type-annotations" "for more advice!"
  ]


toASuperThing :: T.Super -> String
toASuperThing super =
  case super of
    T.Number     -> "a `number` value"
    T.Comparable -> "a `comparable` value"
    T.CompAppend -> "a `compappend` value"
    T.Appendable -> "an `appendable` value"



-- BAD SUPER HINTS


badFlexSuper :: T.Direction -> T.Super -> T.Type -> [D.Doc]
badFlexSuper direction super tipe =
  case super of
    T.Comparable ->
      case tipe of
        T.Record _ _ ->
          [ D.link "Hint"
              "I do not know how to compare records. I can only compare ints, floats,\
              \ chars, strings, lists of comparable values, and tuples of comparable values.\
              \ Check out" "comparing-records" "for ideas on how to proceed."
          ]

        T.Type _ name _ ->
          [ D.toSimpleHint $
              "I do not know how to compare `" ++ T.nameToChars name ++ "` values. I can only\
              \ compare ints, floats, chars, strings, lists of comparable values, and tuples\
              \ of comparable values."
          , D.reflowLink
              "Check out" "comparing-custom-types" "for ideas on how to proceed."
          ]

        _ ->
          [ D.toSimpleHint $
              "I only know how to compare ints, floats, chars, strings, lists of\
              \ comparable values, and tuples of comparable values."
          ]

    T.Appendable ->
      [ D.toSimpleHint "I only know how to append strings and lists."
      ]

    T.CompAppend ->
      [ D.toSimpleHint "Only strings and lists are both comparable and appendable."
      ]

    T.Number ->
      case tipe of
        T.Type home name _ | T.isString home name ->
          case direction of
            T.Have ->
              [ D.toFancyHint ["Try","using",D.green "String.fromInt","to","convert","it","to","a","string?"]
              ]

            T.Need ->
              [ D.toFancyHint ["Try","using",D.green "String.toInt","to","convert","it","to","an","integer?"]
              ]

        _ ->
          [ D.toFancyHint ["Only",D.green "Int","and",D.green "Float","values","work","as","numbers."]
          ]


badRigidSuper :: T.Super -> String -> [D.Doc]
badRigidSuper super aThing =
  let
    (superType, manyThings) =
      case super of
        T.Number -> ("number", "ints AND floats")
        T.Comparable -> ("comparable", "ints, floats, chars, strings, lists, and tuples")
        T.Appendable -> ("appendable", "strings AND lists")
        T.CompAppend -> ("compappend", "strings AND lists")
  in
  [ D.toSimpleHint $
      "The `" ++ superType ++ "` in your type annotation is saying that "
      ++ manyThings ++ " can flow through, but your code is saying it specifically wants "
      ++ aThing ++ ". Maybe change your type annotation to\
      \ be more specific? Maybe change the code to be more general?"
  , D.reflowLink "Read" "type-annotations" "for more advice!"
  ]


badFlexFlexSuper :: T.Super -> T.Super -> [D.Doc]
badFlexFlexSuper s1 s2 =
  let
    likeThis super =
      case super of
        T.Number -> "a number"
        T.Comparable -> "comparable"
        T.CompAppend -> "a compappend"
        T.Appendable -> "appendable"
  in
    [ D.toSimpleHint $
        "There are no values in Elm that are both "
        ++ likeThis s1 ++ " and " ++ likeThis s2 ++ "."
    ]



-- TO EXPR REPORT


toExprReport :: Code.Source -> L.Localizer -> A.Region -> Category -> T.Type -> Expected T.Type -> Report.Report
toExprReport source localizer exprRegion category tipe expected =
  case expected of
    NoExpectation expectedType ->
      Report.Report "TYPE MISMATCH" exprRegion [] $
        Code.toSnippet source exprRegion Nothing
          ( "This expression is being used in an unexpected way:"
          , typeComparison localizer tipe expectedType
              (addCategory "It is" category)
              "But you are trying to use it as:"
              []
          )

    FromAnnotation name _arity subContext expectedType ->
      let
        thing =
          case subContext of
            TypedIfBranch index   -> D.ordinal index <> " branch of this `if` expression:"
            TypedCaseBranch index -> D.ordinal index <> " branch of this `case` expression:"
            TypedBody             -> "body of the `" <> Members.displayName name <> "` definition:"

        itIs =
          case subContext of
            TypedIfBranch index   -> "The " <> D.ordinal index <> " branch is"
            TypedCaseBranch index -> "The " <> D.ordinal index <> " branch is"
            TypedBody             -> "The body is"
      in
      Report.Report "TYPE MISMATCH" exprRegion [] $
        Code.toSnippet source exprRegion Nothing $
          ( D.reflow ("Something is off with the " <> thing)
          , typeComparison localizer tipe expectedType
              (addCategory itIs category)
              ("But the type annotation on `" <> Members.displayName name <> "` says it should be:")
              []
          )

    FromContext region context expectedType ->
      let
        mismatch (maybeHighlight, problem, thisIs, insteadOf, furtherDetails) =
          Report.Report "TYPE MISMATCH" exprRegion [] $
            Code.toSnippet source region maybeHighlight
              ( D.reflow problem
              , typeComparison localizer tipe expectedType (addCategory thisIs category) insteadOf furtherDetails
              )

        badType (maybeHighlight, problem, thisIs, furtherDetails) =
          Report.Report "TYPE MISMATCH" exprRegion [] $
            Code.toSnippet source region maybeHighlight
              ( D.reflow problem
              , loneType localizer tipe expectedType (D.reflow (addCategory thisIs category)) furtherDetails
              )

        custom maybeHighlight docPair =
          Report.Report "TYPE MISMATCH" exprRegion [] $
            Code.toSnippet source region maybeHighlight docPair
      in
      case context of
        ListEntry index ->
          let ith = D.ordinal index in
          mismatch
          ( Just exprRegion
          , "The " <> ith <> " element of this list does not match all the previous elements:"
          , "The " <> ith <> " element is"
          , "But all the previous elements in the list are:"
          , [ D.link "Hint"
                "Everything in a list must be the same type of value. This way, we never\
                \ run into unexpected values partway through a List.map, List.foldl, etc. Read"
                "custom-types"
                "to learn how to “mix” types."
            ]
          )

        Negate ->
          badType
          ( Just exprRegion
          , "I do not know how to negate this type of value:"
          , "It is"
          , [ D.fillSep
                ["But","I","only","now","how","to","negate"
                ,D.dullyellow "Int","and",D.dullyellow "Float","values."
                ]
            ]
          )

        OpLeft op ->
          custom (Just exprRegion) $
            opLeftToDocs localizer category op tipe expectedType

        OpRight op ->
          case opRightToDocs localizer category op tipe expectedType of
            EmphBoth details ->
              custom Nothing details

            EmphRight details ->
              custom (Just exprRegion) details

        IfCondition ->
          badType
          ( Just exprRegion
          , "This `if` condition does not evaluate to a boolean value, True or False."
          , "It is"
          , [ D.fillSep ["But","I","need","this","`if`","condition","to","be","a",D.dullyellow "Bool","value."]
            ]
          )

        IfBranch index ->
          let ith = D.ordinal index in
          mismatch
          ( Just exprRegion
          , "The " <> ith <> " branch of this `if` does not match all the previous branches:"
          , "The " <> ith <> " branch is"
          , "But all the previous branches result in:"
          , [ D.link "Hint"
                "All branches in an `if` must produce the same type of values. This way, no\
                \ matter which branch we take, the result is always a consistent shape. Read"
                "custom-types"
                "to learn how to “mix” types."
            ]
          )

        CaseBranch index ->
          let ith = D.ordinal index in
          mismatch
          ( Just exprRegion
          , "The " <> ith <> " branch of this `case` does not match all the previous branches:"
          , "The " <> ith <> " branch is"
          , "But all the previous branches result in:"
          , [ D.link "Hint"
                "All branches in a `case` must produce the same type of values. This way, no\
                \ matter which branch we take, the result is always a consistent shape. Read"
                "custom-types"
                "to learn how to “mix” types."
            ]
          )

        CallArity maybeFuncName numGivenArgs ->
          Report.Report "TOO MANY ARGS" exprRegion [] $
          Code.toSnippet source region (Just exprRegion) $
          case countArgs tipe of
            0 ->
              let
                thisValue =
                  case maybeFuncName of
                    NoName        -> "This value"
                    FuncName name -> "The `" <> Members.displayName name <> "` value"
                    CtorName name -> "The `" <> Members.displayName name <> "` value"
                    OpName op     -> "The (" <> Op.toChars op <> ") operator"
              in
              ( D.reflow $ thisValue <> " is not a function, but it was given " <> D.args numGivenArgs <> "."
              , D.reflow $ "Are there any missing commas? Or missing parentheses?"
              )

            n ->
              let
                thisFunction =
                  case maybeFuncName of
                    NoName        -> "This function"
                    FuncName name -> "The `" <> Members.displayName name <> "` function"
                    CtorName name -> "The `" <> Members.displayName name <> "` constructor"
                    OpName op     -> "The (" <> Op.toChars op <> ") operator"
              in
              ( D.reflow $ thisFunction <> " expects " <> D.args n <> ", but it got " <> show numGivenArgs <> " instead."
              , D.reflow $ "Are there any missing commas? Or missing parentheses?"
              )

        CallArg maybeFuncName index ->
          let
            ith = D.ordinal index

            thisFunction =
              case maybeFuncName of
                NoName        -> "this function"
                FuncName name -> "`" <> Members.displayName name <> "`"
                CtorName name -> "`" <> Members.displayName name <> "`"
                OpName op     -> "(" <> Op.toChars op <> ")"
          in
          mismatch
          ( Just exprRegion
          , "The " <> ith <> " argument to " <> thisFunction <> " is not what I expect:"
          , "This argument is"
          , "But " <> thisFunction <> " needs the " <> ith <> " argument to be:"
          ,
            if Index.toHuman index == 1 then
              []
            else
              [ D.toSimpleHint $
                 "I always figure out the argument types from left to right. If an argument\
                  \ is acceptable, I assume it is “correct” and move on. So the problem may\
                  \ actually be in one of the previous arguments!"
              ]
          )

        RecordAccess recordRegion maybeName fieldRegion field ->
          case T.iteratedDealias tipe of
            T.Record fields ext ->
              custom (Just fieldRegion)
                ( D.reflow $
                    "This "
                    <> maybe "" (\n -> "`" <> Members.displayName n <> "`") maybeName
                    <> " record does not have a `" <> Members.displayName field <> "` field:"
                , case Suggest.sort (Members.displayName field) (Members.displayName . fst) (Map.toList fields) of
                    [] ->
                      D.reflow "In fact, it is a record with NO fields!"

                    f:fs ->
                      D.stack
                        [ D.reflow $
                            "This is usually a typo. Here are the "
                            <> maybe "" (\n -> "`" <> Members.displayName n <> "`") maybeName
                            <> " fields that are most similar:"
                        , toNearbyRecord localizer f fs ext
                        , D.fillSep
                            ["So","maybe",D.dullyellow (D.fromName field)
                            ,"should","be",D.green (D.fromName (fst f)) <> "?"
                            ]
                        ]
                )

            _ ->
              badType
              ( Just recordRegion
              , "This is not a record, so it has no fields to access!"
              , "It is"
              , [ D.fillSep
                    ["But","I","need","a","record","with","a"
                    ,D.dullyellow (D.fromName field),"field!"
                    ]
                ]
              )

        RecordUpdateKeys record expectedFields ->
          case T.iteratedDealias tipe of
            T.Record actualFields ext ->
              case Map.lookupMin (Map.difference expectedFields actualFields) of
                Nothing ->
                  mismatch
                  ( Nothing
                  , "Something is off with this record update:"
                  , "The `" <> Members.displayName record <> "` record is"
                  , "But this update needs it to be compatable with:"
                  , [ D.reflow
                        "Do you mind creating an <http://sscce.org/> that produces this error message and\
                        \ sharing it at <https://github.com/elm/error-message-catalog/issues> so we\
                        \ can try to give better advice here?"
                    ]
                  )

                Just (field, Can.FieldUpdate fieldRegion _) ->
                  let
                    rStr = "`" <> Members.displayName record <> "`"
                    fStr = "`" <> Members.displayName field <> "`"
                  in
                  custom (Just fieldRegion)
                    ( D.reflow $
                        "The " <> rStr <> " record does not have a " <> fStr <> " field:"
                    , case Suggest.sort (Members.displayName field) (Members.displayName . fst) (Map.toList actualFields) of
                        [] ->
                          D.reflow $ "In fact, " <> rStr <> " is a record with NO fields!"

                        f:fs ->
                          D.stack
                            [ D.reflow $
                                "This is usually a typo. Here are the " <> rStr <> " fields that are most similar:"
                            , toNearbyRecord localizer f fs ext
                            , D.fillSep
                                ["So","maybe",D.dullyellow (D.fromName field)
                                ,"should","be",D.green (D.fromName (fst f)) <> "?"
                                ]
                            ]
                    )

            _ ->
              badType
              ( Just exprRegion
              , "This is not a record, so it has no fields to update!"
              , "It is"
              , [ D.reflow $ "But I need a record!"
                ]
              )

        RecordUpdateValue field ->
          mismatch
          ( Just exprRegion
          , "I cannot update the `" <> Members.displayName field <> "` field like this:"
          , "You are trying to update `" <> Members.displayName field <> "` to be"
          , "But it should be:"
          , [ D.toSimpleNote
                "The record update syntax does not allow you to change the type of fields.\
                \ You can achieve that with record constructors or the record literal syntax."
            ]
          )

        Destructure ->
          mismatch
          ( Nothing
          , "This definition is causing issues:"
          , "You are defining"
          , "But then trying to destructure it as:"
          , []
          )



-- HELPERS


countArgs :: T.Type -> Int
countArgs tipe =
  case tipe of
    T.Lambda _ _ stuff ->
      1 + length stuff

    _ ->
      0



-- FIELD NAME HELPERS


toNearbyRecord :: L.Localizer -> (N.Name, T.Type) -> [(N.Name, T.Type)] -> T.Extension -> D.Doc
toNearbyRecord localizer f fs ext =
  D.indent 4 $
    if length fs <= 3 then
      RT.vrecord (map (fieldToDocs localizer) (f:fs)) (extToDoc ext)
    else
      RT.vrecordSnippet (fieldToDocs localizer f) (map (fieldToDocs localizer) (take 3 fs))


fieldToDocs :: L.Localizer -> (N.Name, T.Type) -> (D.Doc, D.Doc)
fieldToDocs localizer (name, tipe) =
  ( D.fromName name
  , T.toDoc localizer RT.None tipe
  )


extToDoc :: T.Extension -> Maybe D.Doc
extToDoc ext =
  case ext of
    T.Closed      -> Nothing
    T.FlexOpen  x -> Just (D.fromVar x)
    T.RigidOpen x -> Just (D.fromVar x)



-- OP LEFT


opLeftToDocs :: L.Localizer -> Category -> Op.Name -> T.Type -> T.Type -> (D.Doc, D.Doc)
opLeftToDocs localizer category op tipe expected =
  case op of
    "+"
      | isString tipe -> badStringAdd
      | isList tipe   -> badListAdd localizer category "left" tipe expected
      | otherwise     -> badMath localizer category "Addition" "left" "+" tipe expected []

    "*"
      | isList tipe  -> badListMul localizer category "left" tipe expected
      | otherwise    -> badMath localizer category "Multiplication" "left" "*" tipe expected []

    "-"  -> badMath localizer category "Subtraction" "left" "-" tipe expected []
    "^"  -> badMath localizer category "Exponentiation" "left" "^" tipe expected []
    "/"  -> badFDiv localizer "left" tipe expected
    "//" -> badIDiv localizer "left" tipe expected
    "&&" -> badBool localizer "&&" "left" tipe expected
    "||" -> badBool localizer "||" "left" tipe expected
    "<"  -> badCompLeft localizer category "<" "left" tipe expected
    ">"  -> badCompLeft localizer category ">" "left" tipe expected
    "<=" -> badCompLeft localizer category "<=" "left" tipe expected
    ">=" -> badCompLeft localizer category ">=" "left" tipe expected

    "++" -> badAppendLeft localizer category tipe expected

    "<|" ->
      ( "The left side of (<|) needs to be a function so I can pipe arguments to it!"
      , loneType localizer tipe expected
          (D.reflow (addCategory "I am seeing" category))
          [ D.reflow $ "This needs to be some kind of function though!"
          ]
      )

    _ ->
      ( D.reflow $
          "The left argument of (" <> Op.toChars op <> ") is causing problems:"
      , typeComparison localizer tipe expected
          (addCategory "The left argument is" category)
          ("But (" <> Op.toChars op <> ") needs the left argument to be:")
          []
      )



-- OP RIGHT


data RightDocs
  = EmphBoth (D.Doc, D.Doc)
  | EmphRight (D.Doc, D.Doc)


opRightToDocs :: L.Localizer -> Category -> Op.Name -> T.Type -> T.Type -> RightDocs
opRightToDocs localizer category op tipe expected =
  case op of
    "+"
      | isFloat expected && isInt tipe -> badCast op FloatInt
      | isInt expected && isFloat tipe -> badCast op IntFloat
      | isString tipe -> EmphRight $ badStringAdd
      | isList tipe   -> EmphRight $ badListAdd localizer category "right" tipe expected
      | otherwise     -> EmphRight $ badMath localizer category "Addition" "right" "+" tipe expected []

    "*"
      | isFloat expected && isInt tipe -> badCast op FloatInt
      | isInt expected && isFloat tipe -> badCast op IntFloat
      | isList tipe -> EmphRight $ badListMul localizer category "right" tipe expected
      | otherwise   -> EmphRight $ badMath localizer category "Multiplication" "right" "*" tipe expected []

    "-"
      | isFloat expected && isInt tipe -> badCast op FloatInt
      | isInt expected && isFloat tipe -> badCast op IntFloat
      | otherwise ->
          EmphRight $ badMath localizer category "Subtraction" "right" "-" tipe expected []

    "^"
      | isFloat expected && isInt tipe -> badCast op FloatInt
      | isInt expected && isFloat tipe -> badCast op IntFloat
      | otherwise ->
          EmphRight $ badMath localizer category "Exponentiation" "right" "^" tipe expected []

    "/"  -> EmphRight $ badFDiv localizer "right" tipe expected
    "//" -> EmphRight $ badIDiv localizer "right" tipe expected
    "&&" -> EmphRight $ badBool localizer "&&" "right" tipe expected
    "||" -> EmphRight $ badBool localizer "||" "right" tipe expected
    "<"  -> badCompRight localizer "<" tipe expected
    ">"  -> badCompRight localizer ">" tipe expected
    "<=" -> badCompRight localizer "<=" tipe expected
    ">=" -> badCompRight localizer ">=" tipe expected
    "==" -> badEquality localizer "==" tipe expected
    "/=" -> badEquality localizer "/=" tipe expected

    "::" -> badConsRight localizer category tipe expected
    "++" -> badAppendRight localizer category tipe expected

    "<|" ->
      EmphRight
        ( D.reflow $ "I cannot send this through the (<|) pipe:"
        , typeComparison localizer tipe expected
            "The argument is:"
            "But (<|) is piping it to a function that expects:"
            []
        )

    "|>" ->
      case (tipe, expected) of
        (T.Lambda expectedArgType _ _, T.Lambda argType _ _) ->
          EmphRight
            ( D.reflow $ "This function cannot handle the argument sent through the (|>) pipe:"
            , typeComparison localizer argType expectedArgType
                "The argument is:"
                "But (|>) is piping it to a function that expects:"
                []
            )

        _ ->
          EmphRight
            ( D.reflow $ "The right side of (|>) needs to be a function so I can pipe arguments to it!"
            , loneType localizer tipe expected
                (D.reflow (addCategory "But instead of a function, I am seeing" category))
                []
            )

    _ ->
      badOpRightFallback localizer category op tipe expected


badOpRightFallback :: L.Localizer -> Category -> Op.Name -> T.Type -> T.Type -> RightDocs
badOpRightFallback localizer category op tipe expected =
  EmphRight
    ( D.reflow $
        "The right argument of (" <> Op.toChars op <> ") is causing problems."
    , typeComparison localizer tipe expected
        (addCategory "The right argument is" category)
        ("But (" <> Op.toChars op <> ") needs the right argument to be:")
        [ D.toSimpleHint $
            "With operators like (" ++ Op.toChars op ++ ") I always check the left\
            \ side first. If it seems fine, I assume it is correct and check the right\
            \ side. So the problem may be in how the left and right arguments interact!"
        ]
    )


isInt :: T.Type -> Bool
isInt tipe =
  case tipe of
    T.Type home name [] ->
      T.isInt home name

    _ ->
      False


isFloat :: T.Type -> Bool
isFloat tipe =
  case tipe of
    T.Type home name [] ->
      T.isFloat home name

    _ ->
      False


isString :: T.Type -> Bool
isString tipe =
  case tipe of
    T.Type home name [] ->
      T.isString home name

    _ ->
      False


isList :: T.Type -> Bool
isList tipe =
  case tipe of
    T.Type home name [_] ->
      T.isList home name

    _ ->
      False



-- BAD CONS


badConsRight :: L.Localizer -> Category -> T.Type -> T.Type -> RightDocs
badConsRight localizer category tipe expected =
  case tipe of
    T.Type home1 name1 [actualElement] | T.isList home1 name1 ->
      case expected of
        T.Type home2 name2 [expectedElement] | T.isList home2 name2 ->
          EmphBoth
            ( D.reflow "I am having trouble with this (::) operator:"
            , typeComparison localizer expectedElement actualElement
                "The left side of (::) is:"
                "But you are trying to put that into a list filled with:"
                ( case expectedElement of
                    T.Type home name [_] | T.isList home name ->
                      [ D.toSimpleHint
                          "Are you trying to append two lists? The (++) operator\
                          \ appends lists, whereas the (::) operator is only for\
                          \ adding ONE element to a list."
                      ]

                    _ ->
                      [ D.reflow
                          "Lists need ALL elements to be the same type though."
                      ]
                )
            )

        _ ->
          badOpRightFallback localizer category "::" tipe expected

    _ ->
      EmphRight
        ( D.reflow "The (::) operator can only add elements onto lists."
        , loneType localizer tipe expected
            (D.reflow (addCategory "The right side is" category))
            [D.fillSep ["But","(::)","needs","a",D.dullyellow "List","on","the","right."]
            ]
        )



-- BAD APPEND


data AppendType
  = ANumber D.Doc D.Doc
  | AString
  | AList
  | AOther


toAppendType :: T.Type -> AppendType
toAppendType tipe =
  case tipe of
    T.Type home name _
      | T.isInt    home name -> ANumber "Int" "String.fromInt"
      | T.isFloat  home name -> ANumber "Float" "String.fromFloat"
      | T.isString home name -> AString
      | T.isList   home name -> AList

    T.FlexSuper T.Number _ -> ANumber "number" "String.fromInt"

    _ -> AOther


badAppendLeft :: L.Localizer -> Category -> T.Type -> T.Type -> (D.Doc, D.Doc)
badAppendLeft localizer category tipe expected =
  case toAppendType tipe of
    ANumber thing stringFromThing ->
      ( D.fillSep
          ["The","(++)","operator","can","append","List","and","String"
          ,"values,","but","not",D.dullyellow thing,"values","like","this:"
          ]
      , D.fillSep
          ["Try","using",D.green stringFromThing,"to","turn","it","into","a","string?"
          ,"Or","put","it","in","[]","to","make","it","a","list?"
          ,"Or","switch","to","the","(::)","operator?"
          ]
      )

    _ ->
      ( D.reflow $
          "The (++) operator cannot append this type of value:"
      , loneType localizer tipe expected
          (D.reflow (addCategory "I am seeing" category))
          [ D.fillSep
              ["But","the","(++)","operator","is","only","for","appending"
              ,D.dullyellow "List","and",D.dullyellow "String","values."
              ,"Maybe","put","this","value","in","[]","to","make","it","a","list?"
              ]
          ]
      )


badAppendRight :: L.Localizer -> Category -> T.Type -> T.Type -> RightDocs
badAppendRight localizer category tipe expected =
  case (toAppendType expected, toAppendType tipe) of
    (AString, ANumber thing stringFromThing) ->
      EmphRight
        ( D.fillSep
            ["I","thought","I","was","appending",D.dullyellow "String","values","here,"
            ,"not",D.dullyellow thing,"values","like","this:"
            ]
        , D.fillSep
            ["Try","using",D.green stringFromThing,"to","turn","it","into","a","string?"]
        )

    (AList, ANumber thing _) ->
      EmphRight
        ( D.fillSep
            ["I","thought","I","was","appending",D.dullyellow "List","values","here,"
            ,"not",D.dullyellow thing,"values","like","this:"
            ]
        , D.reflow "Try putting it in [] to make it a list?"
        )

    (AString, AList) ->
      EmphBoth
        ( D.reflow $
            "The (++) operator needs the same type of value on both sides:"
        , D.fillSep
            ["I","see","a",D.dullyellow "String","on","the","left","and","a"
            ,D.dullyellow "List","on","the","right.","Which","should","it","be?"
            ,"Does","the","string","need","[]","around","it","to","become","a","list?"
            ]
        )

    (AList, AString) ->
      EmphBoth
        ( D.reflow $
            "The (++) operator needs the same type of value on both sides:"
        , D.fillSep
            ["I","see","a",D.dullyellow "List","on","the","left","and","a"
            ,D.dullyellow "String","on","the","right.","Which","should","it","be?"
            ,"Does","the","string","need","[]","around","it","to","become","a","list?"
            ]
        )

    (_,_) ->
      EmphBoth
        ( D.reflow $
            "The (++) operator cannot append these two values:"
        , typeComparison localizer expected tipe
            "I already figured out that the left side of (++) is:"
            (addCategory "But this clashes with the right side, which is" category)
            []
        )



-- BAD MATH


data ThisThenThat = FloatInt | IntFloat


badCast :: Op.Name -> ThisThenThat -> RightDocs
badCast op thisThenThat =
  EmphBoth
    ( D.reflow $
        "I need both sides of (" <> Op.toChars op <> ") to be the exact same type. Both Int or both Float."
    , let
        anInt = ["an", D.dullyellow "Int"]
        aFloat = ["a", D.dullyellow "Float"]
        toFloat = D.green "toFloat"
        round = D.green "round"
      in
      case thisThenThat of
        FloatInt ->
          badCastHelp aFloat anInt round toFloat

        IntFloat ->
          badCastHelp anInt aFloat toFloat round
    )


badCastHelp :: [D.Doc] -> [D.Doc] -> D.Doc -> D.Doc -> D.Doc
badCastHelp anInt aFloat toFloat round =
  D.stack
    [ D.fillSep $
        ["But","I","see"]
        ++ anInt
        ++ ["on","the","left","and"]
        ++ aFloat
        ++ ["on","the","right."]
    , D.fillSep
        ["Use",toFloat,"on","the","left","(or",round,"on"
        ,"the","right)","to","make","both","sides","match!"
        ]
    , D.link "Note" "Read" "implicit-casts" "to learn why Elm does not implicitly convert Ints to Floats."
    ]


badStringAdd :: (D.Doc, D.Doc)
badStringAdd =
  (
    D.fillSep ["I","cannot","do","addition","with",D.dullyellow "String","values","like","this","one:"]
  ,
    D.stack
      [ D.fillSep
          ["The","(+)","operator","only","works","with",D.dullyellow "Int","and",D.dullyellow "Float","values."
          ]
      , D.toFancyHint
          ["Switch","to","the",D.green "(++)","operator","to","append","strings!"
          ]
      ]
  )


badListAdd :: L.Localizer -> Category -> String -> T.Type -> T.Type -> (D.Doc, D.Doc)
badListAdd localizer category direction tipe expected =
  (
    "I cannot do addition with lists:"
  ,
    loneType localizer tipe expected
      (D.reflow (addCategory ("The " <> direction <> " side of (+) is") category))
      [ D.fillSep
          ["But","(+)","only","works","with",D.dullyellow "Int","and",D.dullyellow "Float","values."
          ]
      , D.toFancyHint
          ["Switch","to","the",D.green "(++)","operator","to","append","lists!"
          ]
      ]
  )


badListMul :: L.Localizer -> Category -> String -> T.Type -> T.Type -> (D.Doc, D.Doc)
badListMul localizer category direction tipe expected =
  badMath localizer category "Multiplication" direction "*" tipe expected
    [
      D.toFancyHint
        [ "Maybe", "you", "want"
        , D.green "List.repeat"
        , "to", "build","a","list","of","repeated","values?"
        ]
    ]


badMath :: L.Localizer -> Category -> String -> String -> String -> T.Type -> T.Type -> [D.Doc] -> (D.Doc, D.Doc)
badMath localizer category operation direction op tipe expected otherHints =
  (
    D.reflow $
      operation ++ " does not work with this value:"
  ,
    loneType localizer tipe expected
      (D.reflow (addCategory ("The " <> direction <> " side of (" <> op <> ") is") category))
      ( [ D.fillSep
            ["But","(" <> D.fromChars op <> ")","only","works","with"
            ,D.dullyellow "Int","and",D.dullyellow "Float","values."
            ]
        ]
        ++ otherHints
      )
  )


badFDiv :: L.Localizer -> D.Doc -> T.Type -> T.Type -> (D.Doc, D.Doc)
badFDiv localizer direction tipe expected =
  (
    D.reflow $
      "The (/) operator is specifically for floating-point division:"
  ,
    if isInt tipe then
      D.stack
        [ D.fillSep
            ["The",direction,"side","of","(/)","must","be","a"
            ,D.dullyellow "Float" <> ","
            ,"but","I","am","seeing","an",D.dullyellow "Int" <> "."
            ,"I","recommend:"
            ]
        , D.vcat
            [ D.green "toFloat" <> " for explicit conversions     " <> D.black "(toFloat 5 / 2) == 2.5"
            , D.green "(//)   " <> " for integer division         " <> D.black "(5 // 2)        == 2"
            ]
        , D.link "Note" "Read" "implicit-casts" "to learn why Elm does not implicitly convert Ints to Floats."
        ]

    else
      loneType localizer tipe expected
        (D.fillSep
          ["The",direction,"side","of","(/)","must","be","a"
          ,D.dullyellow "Float" <> ",","but","instead","I","am","seeing:"
          ]
        )
        []
  )


badIDiv :: L.Localizer -> D.Doc -> T.Type -> T.Type -> (D.Doc, D.Doc)
badIDiv localizer direction tipe expected =
  (
    D.reflow $
      "The (//) operator is specifically for integer division:"
  ,
    if isFloat tipe then
      D.stack
        [ D.fillSep
            ["The",direction,"side","of","(//)","must","be","an"
            ,D.dullyellow "Int" <> ","
            ,"but","I","am","seeing","a",D.dullyellow "Float" <> "."
            ,"I","recommend","doing","the","conversion","explicitly"
            ,"with","one","of","these","functions:"
            ]
        , D.vcat
            [ D.green "round" <> " 3.5     == 4"
            , D.green "floor" <> " 3.5     == 3"
            , D.green "ceiling" <> " 3.5   == 4"
            , D.green "truncate" <> " 3.5  == 3"
            ]
        , D.link "Note" "Read" "implicit-casts" "to learn why Elm does not implicitly convert Ints to Floats."
        ]
    else
      loneType localizer tipe expected
        ( D.fillSep
            ["The",direction,"side","of","(//)","must","be","an"
            ,D.dullyellow "Int" <> ",","but","instead","I","am","seeing:"
            ]
        )
        []
  )



-- BAD BOOLS


badBool :: L.Localizer -> D.Doc -> D.Doc -> T.Type -> T.Type -> (D.Doc, D.Doc)
badBool localizer op direction tipe expected =
  (
    D.reflow $
      "I am struggling with this boolean operation:"
  ,
    loneType localizer tipe expected
      ( D.fillSep
          ["Both","sides","of","(" <> op <> ")","must","be"
          ,D.dullyellow "Bool","values,","but","the",direction,"side","is:"
          ]
      )
      []
  )



-- BAD COMPARISON


badCompLeft :: L.Localizer -> Category -> String -> String -> T.Type -> T.Type -> (D.Doc, D.Doc)
badCompLeft localizer category op direction tipe expected =
  (
    D.reflow $
      "I cannot do a comparison with this value:"
  ,
    loneType localizer tipe expected
      (D.reflow (addCategory ("The " <> direction <> " side of (" <> op <> ") is") category))
      [ D.fillSep
          ["But","(" <> D.fromChars op <> ")","only","works","on"
          ,D.dullyellow "Int" <> ","
          ,D.dullyellow "Float" <> ","
          ,D.dullyellow "Char" <> ","
          ,"and"
          ,D.dullyellow "String"
          ,"values.","It","can","work","on","lists","and","tuples"
          ,"of","comparable","values","as","well,","but","it","is"
          ,"usually","better","to","find","a","different","path."
          ]
      ]
  )


badCompRight :: L.Localizer -> String -> T.Type -> T.Type -> RightDocs
badCompRight localizer op tipe expected =
  EmphBoth
    (
      D.reflow $
        "I need both sides of (" <> op <> ") to be the same type:"
    ,
      typeComparison localizer expected tipe
        ("The left side of (" <> op <> ") is:")
        "But the right side is:"
        [ D.reflow $
            "I cannot compare different types though! Which side of (" <> op <> ") is the problem?"
        ]
    )



-- BAD EQUALITY


badEquality :: L.Localizer -> String -> T.Type -> T.Type -> RightDocs
badEquality localizer op tipe expected =
  EmphBoth
    (
      D.reflow $
        "I need both sides of (" <> op <> ") to be the same type:"
    ,
      typeComparison localizer expected tipe
        ("The left side of (" <> op <> ") is:")
        "But the right side is:"
        [ if isFloat tipe || isFloat expected then
            D.toSimpleNote $
              "Equality on floats is not 100% reliable due to the design of IEEE 754. I\
              \ recommend a check like (abs (x - y) < 0.0001) instead."
          else
            D.reflow  "Different types can never be equal though! Which side is messed up?"
        ]
    )



-- INFINITE TYPES


toRigidEscapeReport :: Code.Source -> A.Region -> N.Name -> String -> Report.Report
toRigidEscapeReport source region name var =
  Report.Report "TYPE MISMATCH" region [] $
    Code.toSnippet source region Nothing
      (
        D.reflow $
          "The type annotation for `" <> Members.displayName name <> "` says the type variable `"
          <> var <> "` can be any type, but the definition ties it to something outside:"
      ,
        D.stack
          [ D.reflow $
              "The body of `" <> Members.displayName name <> "` uses a value that is defined in the code around it,\
              \ and the type of that value is not generalized there. So `" <> var
              <> "` cannot stand for any type here."
          , D.toSimpleHint $
              "In Elm a type variable in an annotation is always a new variable, even when an annotation\
              \ around it uses the same name. So it can only mean \"any type\" if the definition does not\
              \ depend on values from outside whose types are fixed there. Try removing this annotation,\
              \ or write the type that the outside value really has."
          ]
      )


toRunawayReport :: Code.Source -> A.Region -> Bool -> Report.Report
toRunawayReport source region isCycle =
  if isCycle then
    Report.Report "INFINITE TYPE" region [] $
      Code.toSnippet source region Nothing
        (
          D.reflow "I am inferring a weird self-referential type here:"
        ,
          D.stack
            [ D.reflow
                "Two record types here are extensions of the same row variable, but each one adds\
                \ fields that the other does not have. Satisfying that would need a type that contains\
                \ itself again and again, so there is no finite type that fits."
            , D.toSimpleHint
                "Make sure the values meet in a type that lists the fields of both, for example\
                \ by writing the type of the function with an annotation."
            ]
        )
  else
    Report.Report "TYPE TOO COMPLEX" region [] $
      Code.toSnippet source region Nothing
        (
          D.reflow "I gave up on the types here because they are too complex:"
        ,
          D.stack
            [ D.reflow
                "Comparing these types did not finish after a very large number of steps. This usually\
                \ means that a type is being built up again and again, so it would be infinite."
            , D.toSimpleHint
                "Try adding type annotations to the definitions around here. They help me find which\
                \ part does not fit."
            ]
        )


toInfiniteReport :: Code.Source -> L.Localizer -> A.Region -> N.Name -> T.Type -> Report.Report
toInfiniteReport source localizer region name overallType =
  Report.Report "INFINITE TYPE" region [] $
    Code.toSnippet source region Nothing
      (
        D.reflow $
          "I am inferring a weird self-referential type for " <> Members.displayName name <> ":"
      ,
        D.stack
          [ D.reflow $
              "Here is my best effort at writing down the type. You will see ∞ for\
              \ parts of the type that repeat something already printed out infinitely."
          , D.indent 4 (D.dullyellow (T.toDoc localizer RT.None overallType))
          , D.reflowLink
              "Staring at this type is usually not so helpful, so I recommend reading the hints at"
              "infinite-type"
              "to get unstuck!"
          ]
      )
