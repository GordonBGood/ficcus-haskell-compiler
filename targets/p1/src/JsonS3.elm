module JsonS3 exposing (main)

{-| H16a, state S3: S2 with the `oneOf` lists unrolled into dispatch on the first byte (so the commit flags and the failed
alternatives vanish: a parser is `Vector Int -> Int -> ( a, Int )`, the offset -1 is a failure, as in JsonHand) and the top level
parsers (minus, number, fraction, exponent, jnull, jtrue, ..., value, jarray, jobject, member, sepBy) written as plain functions. The
combinator structure is still visible (one function per combinator or grammar rule, `lexeme` = parser followed by `spaces`). Same tree
(JsonTreeV), same checksum as A2.
-}

import JsonConfig
import JsonGen
import JsonTreeV as JsonTree exposing (Json(..))
import Vector exposing (Vector)


byteAt : Int -> Vector Int -> Int
byteAt i src =
    case Vector.get i src of
        Just b ->
            b

        Nothing ->
            -1


isDigit : Int -> Bool
isDigit b =
    b >= 48 && b <= 57


isSpace : Int -> Bool
isSpace b =
    b == 32 || b == 10 || b == 13 || b == 9


nullWord : List Int
nullWord =
    [ 110, 117, 108, 108 ]


trueWord : List Int
trueWord =
    [ 116, 114, 117, 101 ]


falseWord : List Int
falseWord =
    [ 102, 97, 108, 115, 101 ]


noBytes : Vector Int
noBytes =
    Vector.empty


spaces : Vector Int -> Int -> Int
spaces src o =
    if isSpace (byteAt o src) then
        spaces src (o + 1)

    else
        o


{-| lexeme (word codes): the offset after the word and the spaces, or -1
-}
lexWord : Vector Int -> List Int -> Int -> Int
lexWord src codes o =
    case codes of
        [] ->
            spaces src o

        c :: rest ->
            if byteAt o src == c then
                lexWord src rest (o + 1)

            else
                -1


digits : Vector Int -> Int -> Int
digits src o =
    if isDigit (byteAt o src) then
        digits src (o + 1)

    else
        o


digitsValue : Vector Int -> Int -> Int -> Int -> Int
digitsValue src i end acc =
    if i >= end then
        acc

    else
        digitsValue src (i + 1) end (acc * 10 + byteAt i src - 48)


pow10 : Int -> Float
pow10 n =
    if n <= 0 then
        1

    else
        10 * pow10 (n - 1)



-- NUMBERS


{-| the value of one or more digits and the offset after them, -1 without a digit
-}
int10 : Vector Int -> Int -> ( Int, Int )
int10 src o =
    let
        o1 =
            digits src o
    in
    if o1 > o then
        ( digitsValue src o o1 0, o1 )

    else
        ( 0, -1 )


minus : Vector Int -> Int -> ( Bool, Int )
minus src o =
    if byteAt o src == 45 then
        ( True, o + 1 )

    else
        ( False, o )


number : Vector Int -> Int -> ( Float, Int )
number src o =
    let
        ( neg, o1 ) =
            minus src o

        ( x, o2 ) =
            unsignedNumber src o1
    in
    if o2 < 0 then
        ( 0, -1 )

    else if neg then
        ( negate x, o2 )

    else
        ( x, o2 )


unsignedNumber : Vector Int -> Int -> ( Float, Int )
unsignedNumber src o =
    let
        ( ip, o1 ) =
            int10 src o
    in
    if o1 < 0 then
        ( 0, -1 )

    else
        let
            ( fr, o2 ) =
                fraction src o1

            ( ex, o3 ) =
                exponent src o2
        in
        if o3 < 0 then
            ( 0, -1 )

        else
            ( (toFloat ip + fr) * ex, o3 )


fraction : Vector Int -> Int -> ( Float, Int )
fraction src o =
    if byteAt o src == 46 then
        let
            ( v, o1 ) =
                int10 src (o + 1)
        in
        if o1 < 0 then
            ( 0, -1 )

        else
            ( toFloat v / pow10 (o1 - (o + 1)), o1 )

    else
        ( 0, o )


exponent : Vector Int -> Int -> ( Float, Int )
exponent src o =
    let
        b =
            byteAt o src
    in
    if b == 101 || b == 69 then
        exponentBody src (o + 1)

    else
        ( 1, o )


exponentBody : Vector Int -> Int -> ( Float, Int )
exponentBody src o =
    let
        b =
            byteAt o src

        neg =
            b == 45

        start =
            if b == 43 || b == 45 then
                o + 1

            else
                o

        ( e, o1 ) =
            int10 src start
    in
    if o1 < 0 then
        ( 0, -1 )

    else if neg then
        ( 1 / pow10 e, o1 )

    else
        ( pow10 e, o1 )



-- STRINGS


{-| symbol 34, the chunks (plain bytes, or backslash and one byte) up to the closing quote, then lexeme (symbol 34)
-}
stringToken : Vector Int -> Int -> ( Vector Int, Int )
stringToken src o =
    if byteAt o src /= 34 then
        ( noBytes, -1 )

    else
        let
            end =
                stringEnd src (o + 1)
        in
        if end < 0 || byteAt end src /= 34 then
            ( noBytes, -1 )

        else
            ( unescape (Vector.slice (o + 1) end src), spaces src (end + 1) )


stringEnd : Vector Int -> Int -> Int
stringEnd src o =
    let
        b =
            byteAt o src
    in
    if b == 34 then
        o

    else if b < 0 then
        -1

    else if b == 92 then
        if byteAt (o + 1) src < 0 then
            -1

        else
            stringEnd src (o + 2)

    else
        stringEnd src (o + 1)



-- THE GRAMMAR


value : Vector Int -> Int -> ( Json, Int )
value src o =
    let
        b =
            byteAt o src
    in
    if b == 91 then
        jarray src o

    else if b == 123 then
        jobject src o

    else if b == 34 then
        jstring src o

    else if b == 116 then
        jword src trueWord (JBool True) o

    else if b == 102 then
        jword src falseWord (JBool False) o

    else if b == 110 then
        jword src nullWord JNull o

    else
        jnumber src o


jword : Vector Int -> List Int -> Json -> Int -> ( Json, Int )
jword src codes j o =
    let
        o1 =
            lexWord src codes o
    in
    if o1 < 0 then
        ( JNull, -1 )

    else
        ( j, o1 )


jnumber : Vector Int -> Int -> ( Json, Int )
jnumber src o =
    let
        ( x, o1 ) =
            number src o
    in
    if o1 < 0 then
        ( JNull, -1 )

    else
        ( JNum x, spaces src o1 )


jstring : Vector Int -> Int -> ( Json, Int )
jstring src o =
    let
        ( s, o1 ) =
            stringToken src o
    in
    if o1 < 0 then
        ( JNull, -1 )

    else
        ( JStr s, o1 )


jarray : Vector Int -> Int -> ( Json, Int )
jarray src o =
    let
        ( xs, o1 ) =
            sepByValue src (spaces src (o + 1))
    in
    if o1 < 0 || byteAt o1 src /= 93 then
        ( JNull, -1 )

    else
        ( JArr xs, spaces src (o1 + 1) )


jobject : Vector Int -> Int -> ( Json, Int )
jobject src o =
    let
        ( xs, o1 ) =
            sepByMember src (spaces src (o + 1))
    in
    if o1 < 0 || byteAt o1 src /= 125 then
        ( JNull, -1 )

    else
        ( JObj xs, spaces src (o1 + 1) )


member : Vector Int -> Int -> ( ( Vector Int, Json ), Int )
member src o =
    let
        ( k, o1 ) =
            stringToken src o
    in
    if o1 < 0 || byteAt o1 src /= 58 then
        ( ( noBytes, JNull ), -1 )

    else
        let
            ( v, o2 ) =
                value src (spaces src (o1 + 1))
        in
        if o2 < 0 then
            ( ( noBytes, JNull ), -1 )

        else
            ( ( k, v ), o2 )


sepByValue : Vector Int -> Int -> ( Vector Json, Int )
sepByValue src o =
    let
        ( x, o1 ) =
            value src o
    in
    if o1 < 0 then
        ( Vector.empty, o )

    else
        sepByValueHelp src (Vector.singleton x) o1


sepByValueHelp : Vector Int -> Vector Json -> Int -> ( Vector Json, Int )
sepByValueHelp src acc o =
    if byteAt o src == 44 then
        let
            ( y, o1 ) =
                value src (spaces src (o + 1))
        in
        if o1 < 0 then
            ( Vector.empty, -1 )

        else
            sepByValueHelp src (Vector.push y acc) o1

    else
        ( acc, o )


sepByMember : Vector Int -> Int -> ( Vector ( Vector Int, Json ), Int )
sepByMember src o =
    let
        ( x, o1 ) =
            member src o
    in
    if o1 < 0 then
        ( Vector.empty, o )

    else
        sepByMemberHelp src (Vector.singleton x) o1


sepByMemberHelp : Vector Int -> Vector ( Vector Int, Json ) -> Int -> ( Vector ( Vector Int, Json ), Int )
sepByMemberHelp src acc o =
    if byteAt o src == 44 then
        let
            ( y, o1 ) =
                member src (spaces src (o + 1))
        in
        if o1 < 0 then
            ( Vector.empty, -1 )

        else
            sepByMemberHelp src (Vector.push y acc) o1

    else
        ( acc, o )


parseDocument : Vector Int -> Result String Json
parseDocument src =
    let
        ( v, o ) =
            value src (spaces src 0)
    in
    if o == Vector.length src then
        Ok v

    else
        Err "parse error"





-- ESCAPES (on the bytes of a string token; \u escapes are encoded as UTF-8)


unescape : Vector Int -> Vector Int
unescape raw =
    if Vector.foldl (\b f -> f || b == 92) False raw then
        unescapeFrom raw 0 (Vector.withCapacity (Vector.length raw))

    else
        raw


unescapeFrom : Vector Int -> Int -> Vector Int -> Vector Int
unescapeFrom raw i acc =
    case Vector.get i raw of
        Nothing ->
            acc

        Just b ->
            if b /= 92 then
                unescapeFrom raw (i + 1) (Vector.push b acc)

            else
                case Vector.get (i + 1) raw of
                    Nothing ->
                        acc

                    Just c ->
                        if c == 110 then
                            unescapeFrom raw (i + 2) (Vector.push 10 acc)

                        else if c == 116 then
                            unescapeFrom raw (i + 2) (Vector.push 9 acc)

                        else if c == 98 then
                            unescapeFrom raw (i + 2) (Vector.push 8 acc)

                        else if c == 102 then
                            unescapeFrom raw (i + 2) (Vector.push 12 acc)

                        else if c == 114 then
                            unescapeFrom raw (i + 2) (Vector.push 13 acc)

                        else if c == 117 then
                            unescapeFrom raw (i + 6) (utf8Append acc (hexAt raw (i + 2) * 4096 + hexAt raw (i + 3) * 256 + hexAt raw (i + 4) * 16 + hexAt raw (i + 5)))

                        else
                            unescapeFrom raw (i + 2) (Vector.push c acc)


hexAt : Vector Int -> Int -> Int
hexAt raw i =
    let
        n =
            byteAt i raw
    in
    if n >= 97 then
        n - 87

    else if n >= 65 then
        n - 55

    else
        n - 48


{-| append the UTF-8 encoding of a code point below 65536 -}
utf8Append : Vector Int -> Int -> Vector Int
utf8Append acc code =
    if code < 128 then
        Vector.push code acc

    else if code < 2048 then
        acc |> Vector.push (code // 64 + 192) |> Vector.push (modBy 64 code + 128)

    else
        acc |> Vector.push (code // 4096 + 224) |> Vector.push (modBy 64 (code // 64) + 128) |> Vector.push (modBy 64 code + 128)



-- MAIN


toVector : String -> Vector Int
toVector text =
    String.foldl (\c v -> Vector.push (Char.toCode c) v) (Vector.withCapacity (String.length text)) text


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
                            let
                                src =
                                    toVector text
                            in
                            if JsonConfig.stage == 1 then
                                "vector length " ++ String.fromInt (Vector.length src)

                            else
                                case parseDocument src of
                                    Ok j ->
                                        JsonTree.report (JsonTree.summarize j)

                                    Err e ->
                                        "error " ++ e

                    _ =
                        Debug.log answer ()
                in
                ( (), Cmd.none )
        , update = \_ _ -> ( (), Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
