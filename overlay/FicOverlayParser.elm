module FicOverlayParser exposing (multiComment)

{-| Ficcus: elm/parser's `multiComment` with the fix of decision L33 (parser#2): for `NotNestable` Elm's version is
`token open |. chompUntil close`, and because of the way `chompUntil` leaves the offset (before the terminator, the position
after it) the closing token is never consumed. Here the comment is read up to and including the closing token with the
public API only. `Nestable` is elm/parser's own `nestableComment` (copied: it is not exported). Compiled only into projects
that depend on elm/parser (Ficcus.Mono.Overlay); the specializer redirects `Parser.Advanced.multiComment` here.
-}

import Parser.Advanced exposing ((|.), Nestable(..), Parser, Token(..), andThen, chompIf, chompWhile, oneOf, problem, token)


multiComment : Token x -> Token x -> Nestable -> Parser c x ()
multiComment open close nestable =
    case nestable of
        NotNestable ->
            notNestableComment open close

        Nestable ->
            nestableComment open close


notNestableComment : Token x -> Token x -> Parser c x ()
notNestableComment (Token _ _ as open) (Token cStr cX as close) =
    case String.uncons cStr of
        Nothing ->
            problem cX

        Just ( closeChar, _ ) ->
            token open |. notNestableHelp (\char -> char /= closeChar) (token close) cX


notNestableHelp : (Char -> Bool) -> Parser c x () -> x -> Parser c x ()
notNestableHelp isNotClose close expectingClose =
    chompWhile isNotClose
        |. oneOf
            [ close
            , chompIf isChar expectingClose
                |> andThen (\_ -> notNestableHelp isNotClose close expectingClose)
            ]


nestableComment : Token x -> Token x -> Parser c x ()
nestableComment (Token oStr oX as open) (Token cStr cX as close) =
    case String.uncons oStr of
        Nothing ->
            problem oX

        Just ( openChar, _ ) ->
            case String.uncons cStr of
                Nothing ->
                    problem cX

                Just ( closeChar, _ ) ->
                    let
                        isNotRelevant char =
                            char /= openChar && char /= closeChar

                        chompOpen =
                            token open
                    in
                    chompOpen |. nestableHelp isNotRelevant chompOpen (token close) cX 1


nestableHelp : (Char -> Bool) -> Parser c x () -> Parser c x () -> x -> Int -> Parser c x ()
nestableHelp isNotRelevant open close expectingClose nestLevel =
    chompWhile isNotRelevant
        |. oneOf
            [ if nestLevel == 1 then
                close

              else
                close
                    |> andThen (\_ -> nestableHelp isNotRelevant open close expectingClose (nestLevel - 1))
            , open
                |> andThen (\_ -> nestableHelp isNotRelevant open close expectingClose (nestLevel + 1))
            , chompIf isChar expectingClose
                |> andThen (\_ -> nestableHelp isNotRelevant open close expectingClose nestLevel)
            ]


isChar : Char -> Bool
isChar _ =
    True
