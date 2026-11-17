module JsonPkg exposing (main)

{-| P1, version B (1 MB only): the same JSON grammar on the real elm/parser package (String source, the package's kernel with its offset
cache), for reference. Same tree and checksum as JsonComb.elm. Recursive rules are functions of `()` as in JsonComb.elm.
-}

import JsonConfig
import JsonGen
import JsonTree exposing (Json(..))
import Parser exposing ((|.), (|=), Parser, Step(..), andThen, chompIf, chompWhile, end, getChompedString, keyword, lazy, loop, number, oneOf, spaces, succeed, symbol)


value : Parser Json
value =
    lazy (\_ -> oneOf [ jarray (), jobject (), jstring, jnumber, jtrue, jfalse, jnull ])


jnull : Parser Json
jnull =
    succeed JNull |. keyword "null" |. spaces


jtrue : Parser Json
jtrue =
    succeed (JBool True) |. keyword "true" |. spaces


jfalse : Parser Json
jfalse =
    succeed (JBool False) |. keyword "false" |. spaces


jnumber : Parser Json
jnumber =
    succeed JNum
        |= oneOf
            [ succeed negate |. symbol "-" |= unsigned
            , unsigned
            ]
        |. spaces


unsigned : Parser Float
unsigned =
    number { int = Just toFloat, hex = Nothing, octal = Nothing, binary = Nothing, float = Just identity }


jstring : Parser Json
jstring =
    succeed JStr |= stringToken


stringToken : Parser String
stringToken =
    succeed unescape
        |. symbol "\""
        |= getChompedString stringBody
        |. symbol "\""
        |. spaces


stringBody : Parser ()
stringBody =
    loop () (\_ -> oneOf [ succeed (Loop ()) |. stringChunk, succeed (Done ()) ])


stringChunk : Parser ()
stringChunk =
    oneOf
        [ chompIf isPlain |. chompWhile isPlain
        , symbol "\\" |. chompIf (\_ -> True)
        ]


isPlain : Char -> Bool
isPlain c =
    c /= '"' && c /= '\\'


jarray : () -> Parser Json
jarray _ =
    succeed JArr
        |. symbol "["
        |. spaces
        |= sepBy value
        |. symbol "]"
        |. spaces


jobject : () -> Parser Json
jobject _ =
    succeed JObj
        |. symbol "{"
        |. spaces
        |= sepBy (member ())
        |. symbol "}"
        |. spaces


member : () -> Parser ( String, Json )
member _ =
    succeed (\k v -> ( k, v ))
        |= stringToken
        |. symbol ":"
        |. spaces
        |= value


sepBy : Parser a -> Parser (List a)
sepBy item =
    oneOf
        [ Parser.map List.reverse (andThen (\x -> loop [ x ] (sepByStep item)) item)
        , succeed []
        ]


sepByStep : Parser a -> List a -> Parser (Step (List a) (List a))
sepByStep item acc =
    oneOf
        [ succeed (\y -> Loop (y :: acc)) |. symbol "," |. spaces |= item
        , succeed (Done acc)
        ]


document : Parser Json
document =
    succeed identity |. spaces |= value |. end



-- ESCAPES (a String of a string token; the text of the token is short)


unescape : String -> String
unescape raw =
    if String.contains "\\" raw then
        String.fromList (unescapeList (String.toList raw))

    else
        raw


unescapeList : List Char -> List Char
unescapeList cs =
    case cs of
        [] ->
            []

        '\\' :: c :: rest ->
            case c of
                'n' ->
                    '\n' :: unescapeList rest

                't' ->
                    '\t' :: unescapeList rest

                'b' ->
                    Char.fromCode 8 :: unescapeList rest

                'f' ->
                    Char.fromCode 12 :: unescapeList rest

                'r' ->
                    '\u{000D}' :: unescapeList rest

                'u' ->
                    case rest of
                        a :: b :: c2 :: d :: rest2 ->
                            Char.fromCode (hex a * 4096 + hex b * 256 + hex c2 * 16 + hex d) :: unescapeList rest2

                        _ ->
                            []

                _ ->
                    c :: unescapeList rest

        c :: rest ->
            c :: unescapeList rest


hex : Char -> Int
hex c =
    let
        n =
            Char.toCode c
    in
    if n >= 97 then
        n - 87

    else if n >= 65 then
        n - 55

    else
        n - 48



main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    text =
                        JsonGen.document JsonConfig.records

                    answer =
                        if JsonConfig.stage == 0 then
                            "text length " ++ String.fromInt (String.length text)

                        else
                            case Parser.run document text of
                                Ok j ->
                                    JsonTree.report (JsonTree.summarize j)

                                Err _ ->
                                    "error"

                    _ =
                        Debug.log answer ()
                in
                ( (), Cmd.none )
        , update = \_ _ -> ( (), Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
