module JsonHand exposing (main)

{-| P1, version C: the same JSON parser written by hand as a recursive descent, without combinators. Same input (a `Vector Int` of
byte values), same tree, same checksum as version A (JsonComb.elm); A against C is the combinator overhead. A syntax error gives
`JNull` and offset -1 (the generated document is valid).
-}

import JsonConfig
import JsonGen
import JsonTree exposing (Json(..))
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


skipSpaces : Vector Int -> Int -> Int
skipSpaces src i =
    let
        b =
            byteAt i src
    in
    if b == 32 || b == 10 || b == 13 || b == 9 then
        skipSpaces src (i + 1)

    else
        i


parseValue : Vector Int -> Int -> ( Json, Int )
parseValue src i =
    let
        b =
            byteAt i src
    in
    if b == 91 then
        parseArray src (skipSpaces src (i + 1))

    else if b == 123 then
        parseObject src (skipSpaces src (i + 1))

    else if b == 34 then
        let
            ( s, j ) =
                parseString src (i + 1)
        in
        ( JStr s, skipSpaces src j )

    else if b == 116 then
        ( JBool True, skipSpaces src (i + 4) )

    else if b == 102 then
        ( JBool False, skipSpaces src (i + 5) )

    else if b == 110 then
        ( JNull, skipSpaces src (i + 4) )

    else
        let
            ( x, j ) =
                parseNumber src i
        in
        if j < 0 then
            ( JNull, -1 )

        else
            ( JNum x, skipSpaces src j )


parseArray : Vector Int -> Int -> ( Json, Int )
parseArray src i =
    if byteAt i src == 93 then
        ( JArr [], skipSpaces src (i + 1) )

    else
        arrayItems src i []


arrayItems : Vector Int -> Int -> List Json -> ( Json, Int )
arrayItems src i acc =
    let
        ( v, j ) =
            parseValue src i
    in
    if j < 0 then
        ( JNull, -1 )

    else
        let
            b =
                byteAt j src
        in
        if b == 44 then
            arrayItems src (skipSpaces src (j + 1)) (v :: acc)

        else if b == 93 then
            ( JArr (List.reverse (v :: acc)), skipSpaces src (j + 1) )

        else
            ( JNull, -1 )


parseObject : Vector Int -> Int -> ( Json, Int )
parseObject src i =
    if byteAt i src == 125 then
        ( JObj [], skipSpaces src (i + 1) )

    else
        objectMembers src i []


objectMembers : Vector Int -> Int -> List ( String, Json ) -> ( Json, Int )
objectMembers src i acc =
    if byteAt i src /= 34 then
        ( JNull, -1 )

    else
        let
            ( k, j ) =
                parseString src (i + 1)

            j2 =
                skipSpaces src j
        in
        if byteAt j2 src /= 58 then
            ( JNull, -1 )

        else
            let
                ( v, j3 ) =
                    parseValue src (skipSpaces src (j2 + 1))
            in
            if j3 < 0 then
                ( JNull, -1 )

            else
                let
                    b =
                        byteAt j3 src
                in
                if b == 44 then
                    objectMembers src (skipSpaces src (j3 + 1)) (( k, v ) :: acc)

                else if b == 125 then
                    ( JObj (List.reverse (( k, v ) :: acc)), skipSpaces src (j3 + 1) )

                else
                    ( JNull, -1 )


{-| i is just after the opening quote; the result is the decoded string and the offset after the closing quote (and spaces)
-}
parseString : Vector Int -> Int -> ( String, Int )
parseString src i =
    let
        end =
            stringEnd src i
    in
    ( unescape (bytesToString i end src), skipSpaces src (end + 1) )


stringEnd : Vector Int -> Int -> Int
stringEnd src i =
    let
        b =
            byteAt i src
    in
    if b == 34 || b < 0 then
        i

    else if b == 92 then
        stringEnd src (i + 2)

    else
        stringEnd src (i + 1)


bytesToString : Int -> Int -> Vector Int -> String
bytesToString from to src =
    String.fromList (bytesToChars src from (to - 1) [])


bytesToChars : Vector Int -> Int -> Int -> List Char -> List Char
bytesToChars src from i acc =
    if i < from then
        acc

    else
        bytesToChars src from (i - 1) (Char.fromCode (byteAt i src) :: acc)


{-| a number: optional minus, digits, optional fraction, optional exponent; offset -1 when there is no digit
-}
parseNumber : Vector Int -> Int -> ( Float, Int )
parseNumber src i =
    let
        neg =
            byteAt i src == 45

        i1 =
            if neg then
                i + 1

            else
                i

        i2 =
            digitsEnd src i1
    in
    if i2 == i1 then
        ( 0, -1 )

    else
        let
            ip =
                digitsValue src i1 i2 0

            ( fr, i3 ) =
                if byteAt i2 src == 46 then
                    let
                        j =
                            digitsEnd src (i2 + 1)
                    in
                    ( toFloat (digitsValue src (i2 + 1) j 0) / pow10 (j - i2 - 1), j )

                else
                    ( 0, i2 )

            b3 =
                byteAt i3 src

            ( ex, i4 ) =
                if b3 == 101 || b3 == 69 then
                    parseExponent src (i3 + 1)

                else
                    ( 1, i3 )

            x =
                (toFloat ip + fr) * ex
        in
        ( if neg then
            negate x

          else
            x
        , i4
        )


parseExponent : Vector Int -> Int -> ( Float, Int )
parseExponent src i =
    let
        b =
            byteAt i src

        i1 =
            if b == 43 || b == 45 then
                i + 1

            else
                i

        i2 =
            digitsEnd src i1

        e =
            digitsValue src i1 i2 0
    in
    ( if b == 45 then
        1 / pow10 e

      else
        pow10 e
    , i2
    )


digitsEnd : Vector Int -> Int -> Int
digitsEnd src i =
    if isDigit (byteAt i src) then
        digitsEnd src (i + 1)

    else
        i


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


parseDocument : Vector Int -> Result String Json
parseDocument src =
    let
        ( v, j ) =
            parseValue src (skipSpaces src 0)
    in
    if j == Vector.length src then
        Ok v

    else
        Err "syntax error"



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
