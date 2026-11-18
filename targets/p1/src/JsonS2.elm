module JsonS2 exposing (main)

{-| H16a, state S2: S1 with the `Step` values collapsed. A parser is `Vector Int -> Int -> R a`, `R a` a record (a C struct returned by
value, no heap object): `ok` tells Good from Bad, `c` is the commit flag, `v` the value (a placeholder when `ok` is False), `o` the new
offset. Every `case f s of Good .. / Bad ..` of S1 is now a field test on the struct that the callee just built: the Good/Bad cell is
not allocated, and the state record `{ src, offset }` is split into the source (a borrowed argument, never dup'ed) and an Int offset.
The Bad message (a String no program reads, except `Err` of a failed document) is dropped; the `Loop` value of the string loop is
the Bool of `v` (True = More). `sepBy` is specialized per item (`value`, `member`): no function value remains. Same tree, same checksum.
-}

import JsonConfig
import JsonGen
import JsonTreeV as JsonTree exposing (Json(..))
import Vector exposing (Vector)


type alias R a =
    { ok : Bool, c : Bool, v : a, o : Int }


good : Bool -> a -> Int -> R a
good c v o =
    { ok = True, c = c, v = v, o = o }


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


isPlain : Int -> Bool
isPlain b =
    b /= 34 && b /= 92


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


badU : Bool -> R ()
badU c =
    { ok = False, c = c, v = (), o = 0 }


badB : Bool -> R Bool
badB c =
    { ok = False, c = c, v = False, o = 0 }


badI : Bool -> R Int
badI c =
    { ok = False, c = c, v = 0, o = 0 }


badF : Bool -> R Float
badF c =
    { ok = False, c = c, v = 0, o = 0 }


badJ : Bool -> R Json
badJ c =
    { ok = False, c = c, v = JNull, o = 0 }


badBytes : Bool -> R (Vector Int)
badBytes c =
    { ok = False, c = c, v = noBytes, o = 0 }



-- PRIMITIVES


symbol : Vector Int -> Int -> Int -> R ()
symbol src o code =
    if byteAt o src == code then
        good True () (o + 1)

    else
        badU False


wordHelp : Vector Int -> List Int -> Int -> Int -> R ()
wordHelp src codes start o =
    case codes of
        [] ->
            good True () o

        c :: rest ->
            if byteAt o src == c then
                wordHelp src rest start (o + 1)

            else
                badU (o > start)


chompWhileSpace : Vector Int -> Int -> Int
chompWhileSpace src o =
    if isSpace (byteAt o src) then
        chompWhileSpace src (o + 1)

    else
        o


chompWhilePlain : Vector Int -> Int -> Int
chompWhilePlain src o =
    let
        b =
            byteAt o src
    in
    if b >= 0 && isPlain b then
        chompWhilePlain src (o + 1)

    else
        o


chompWhileDigit : Vector Int -> Int -> Int
chompWhileDigit src o =
    if isDigit (byteAt o src) then
        chompWhileDigit src (o + 1)

    else
        o


spaces : Vector Int -> Int -> R ()
spaces src o =
    let
        o1 =
            chompWhileSpace src o
    in
    good (o1 > o) () o1


lexSym : Vector Int -> Int -> Int -> R ()
lexSym src o code =
    let
        r1 =
            symbol src o code
    in
    if r1.ok then
        let
            r2 =
                spaces src r1.o
        in
        good (r1.c || r2.c) () r2.o

    else
        badU r1.c


lexWord : Vector Int -> List Int -> Int -> R ()
lexWord src codes o =
    let
        r1 =
            wordHelp src codes o o
    in
    if r1.ok then
        let
            r2 =
                spaces src r1.o
        in
        good (r1.c || r2.c) () r2.o

    else
        badU r1.c


int10 : Vector Int -> Int -> R Int
int10 src o =
    let
        o1 =
            chompWhileDigit src o
    in
    if o1 > o then
        good True (digitsValue src o o1 0) o1

    else
        badI False


digitsValue : Vector Int -> Int -> Int -> Int -> Int
digitsValue src i end acc =
    if i >= end then
        acc

    else
        digitsValue src (i + 1) end (acc * 10 + byteAt i src - 48)


applySign : Bool -> Float -> Float
applySign neg x =
    if neg then
        negate x

    else
        x


exponentFactor : Bool -> Int -> Float
exponentFactor neg e =
    if neg then
        1 / pow10 e

    else
        pow10 e


pow10 : Int -> Float
pow10 n =
    if n <= 0 then
        1

    else
        10 * pow10 (n - 1)



-- NUMBERS


minus : Vector Int -> Int -> R Bool
minus src o =
    let
        r =
            symbol src o 45
    in
    if r.ok then
        good r.c True r.o

    else if r.c then
        badB True

    else
        good False False o


number : Vector Int -> Int -> R Float
number src o =
    let
        r1 =
            minus src o
    in
    if r1.ok then
        let
            r2 =
                unsignedNumber src r1.o
        in
        if r2.ok then
            good (r1.c || r2.c) (applySign r1.v r2.v) r2.o

        else
            badF (r1.c || r2.c)

    else
        badF r1.c


unsignedNumber : Vector Int -> Int -> R Float
unsignedNumber src o =
    let
        r1 =
            int10 src o
    in
    if r1.ok then
        let
            r2 =
                fraction src r1.o
        in
        if r2.ok then
            let
                r3 =
                    exponent src r2.o
            in
            if r3.ok then
                good (r1.c || (r2.c || r3.c)) ((toFloat r1.v + r2.v) * r3.v) r3.o

            else
                badF (r1.c || (r2.c || r3.c))

        else
            badF (r1.c || r2.c)

    else
        badF r1.c


fraction : Vector Int -> Int -> R Float
fraction src o =
    let
        r1 =
            symbol src o 46
    in
    if r1.ok then
        let
            r2 =
                fractionDigits src r1.o
        in
        if r2.ok then
            good (r1.c || r2.c) r2.v r2.o

        else if r1.c || r2.c then
            badF True

        else
            good False 0 o

    else if r1.c then
        badF True

    else
        good False 0 o


fractionDigits : Vector Int -> Int -> R Float
fractionDigits src o =
    let
        r =
            int10 src o
    in
    if r.ok then
        good r.c (toFloat r.v / pow10 (r.o - o)) r.o

    else
        badF r.c


exponent : Vector Int -> Int -> R Float
exponent src o =
    let
        r1 =
            exponentMark src o
    in
    if r1.ok then
        let
            r2 =
                exponentBody src r1.o
        in
        if r2.ok then
            good (r1.c || r2.c) r2.v r2.o

        else if r1.c || r2.c then
            badF True

        else
            good False 1 o

    else if r1.c then
        badF True

    else
        good False 1 o


exponentMark : Vector Int -> Int -> R ()
exponentMark src o =
    let
        r =
            symbol src o 101
    in
    if r.ok then
        r

    else if r.c then
        r

    else
        let
            r2 =
                symbol src o 69
        in
        if r2.ok then
            r2

        else
            badU False


exponentBody : Vector Int -> Int -> R Float
exponentBody src o =
    let
        r1 =
            exponentSign src o
    in
    if r1.ok then
        let
            r2 =
                int10 src r1.o
        in
        if r2.ok then
            good (r1.c || r2.c) (exponentFactor r1.v r2.v) r2.o

        else
            badF (r1.c || r2.c)

    else
        badF r1.c


exponentSign : Vector Int -> Int -> R Bool
exponentSign src o =
    let
        r =
            symbol src o 43
    in
    if r.ok then
        good r.c False r.o

    else if r.c then
        badB True

    else
        let
            r2 =
                symbol src o 45
        in
        if r2.ok then
            good r2.c True r2.o

        else if r2.c then
            badB True

        else
            good False False o



-- STRINGS


stringToken : Vector Int -> Int -> R (Vector Int)
stringToken src o =
    let
        r1 =
            symbol src o 34
    in
    if r1.ok then
        let
            r2 =
                stringChomped src r1.o
        in
        let
            r3 =
                lexSym src r2.o 34
        in
        if r3.ok then
            good ((r1.c || r2.c) || r3.c) (unescape r2.v) r3.o

        else
            badBytes ((r1.c || r2.c) || r3.c)

    else
        badBytes r1.c


{-| stringBody never fails
-}
stringChomped : Vector Int -> Int -> R (Vector Int)
stringChomped src o =
    let
        r =
            stringBody src False o
    in
    good r.c (Vector.slice o r.o src) r.o


stringBody : Vector Int -> Bool -> Int -> R ()
stringBody src p o =
    let
        r =
            stringStep src o
    in
    if r.ok then
        if r.v then
            stringBody src (p || r.c) r.o

        else
            good (p || r.c) () r.o

    else
        badU (p || r.c)


{-| the oneOf of the string loop: v = True is More, False is Done
-}
stringStep : Vector Int -> Int -> R Bool
stringStep src o =
    let
        r =
            stringChunk src o
    in
    if r.ok then
        good r.c True r.o

    else if r.c then
        badB True

    else
        good False False o


stringChunk : Vector Int -> Int -> R ()
stringChunk src o =
    let
        b =
            byteAt o src
    in
    if b >= 0 && isPlain b then
        good True () (chompWhilePlain src (o + 1))

    else
        let
            r =
                escape src o
        in
        if r.ok then
            r

        else if r.c then
            r

        else
            badU False


escape : Vector Int -> Int -> R ()
escape src o =
    if byteAt o src == 92 then
        if byteAt (o + 1) src >= 0 then
            good True () (o + 2)

        else
            badU True

    else
        badU False



-- THE GRAMMAR


jnull : Vector Int -> Int -> R Json
jnull src o =
    let
        r =
            lexWord src nullWord o
    in
    if r.ok then
        good r.c JNull r.o

    else
        badJ r.c


jtrue : Vector Int -> Int -> R Json
jtrue src o =
    let
        r =
            lexWord src trueWord o
    in
    if r.ok then
        good r.c (JBool True) r.o

    else
        badJ r.c


jfalse : Vector Int -> Int -> R Json
jfalse src o =
    let
        r =
            lexWord src falseWord o
    in
    if r.ok then
        good r.c (JBool False) r.o

    else
        badJ r.c


jnumber : Vector Int -> Int -> R Json
jnumber src o =
    let
        r1 =
            number src o
    in
    if r1.ok then
        let
            r2 =
                spaces src r1.o
        in
        good (r1.c || r2.c) (JNum r1.v) r2.o

    else
        badJ r1.c


jstring : Vector Int -> Int -> R Json
jstring src o =
    let
        r =
            stringToken src o
    in
    if r.ok then
        good r.c (JStr r.v) r.o

    else
        badJ r.c


jarray : Vector Int -> Int -> R Json
jarray src o =
    let
        r1 =
            lexSym src o 91
    in
    if r1.ok then
        let
            r2 =
                sepByValue src r1.o
        in
        if r2.ok then
            let
                r3 =
                    lexSym src r2.o 93
            in
            if r3.ok then
                good ((r1.c || r2.c) || r3.c) (JArr r2.v) r3.o

            else
                badJ ((r1.c || r2.c) || r3.c)

        else
            badJ (r1.c || r2.c)

    else
        badJ r1.c


jobject : Vector Int -> Int -> R Json
jobject src o =
    let
        r1 =
            lexSym src o 123
    in
    if r1.ok then
        let
            r2 =
                sepByMember src r1.o
        in
        if r2.ok then
            let
                r3 =
                    lexSym src r2.o 125
            in
            if r3.ok then
                good ((r1.c || r2.c) || r3.c) (JObj r2.v) r3.o

            else
                badJ ((r1.c || r2.c) || r3.c)

        else
            badJ (r1.c || r2.c)

    else
        badJ r1.c


member : Vector Int -> Int -> R ( Vector Int, Json )
member src o =
    let
        r1 =
            stringToken src o
    in
    if r1.ok then
        let
            r2 =
                lexSym src r1.o 58
        in
        if r2.ok then
            let
                r3 =
                    value src r2.o
            in
            if r3.ok then
                good (r1.c || (r2.c || r3.c)) ( r1.v, r3.v ) r3.o

            else
                { ok = False, c = r1.c || (r2.c || r3.c), v = ( noBytes, JNull ), o = 0 }

        else
            { ok = False, c = r1.c || r2.c, v = ( noBytes, JNull ), o = 0 }

    else
        { ok = False, c = r1.c, v = ( noBytes, JNull ), o = 0 }


{-| the oneOf of the seven alternatives under lazy: the first that succeeds, or fails having consumed input, decides
-}
value : Vector Int -> Int -> R Json
value src o =
    let
        r1 =
            jarray src o
    in
    if r1.ok || r1.c then
        r1

    else
        let
            r2 =
                jobject src o
        in
        if r2.ok || r2.c then
            r2

        else
            let
                r3 =
                    jstring src o
            in
            if r3.ok || r3.c then
                r3

            else
                let
                    r4 =
                        jnumber src o
                in
                if r4.ok || r4.c then
                    r4

                else
                    let
                        r5 =
                            jtrue src o
                    in
                    if r5.ok || r5.c then
                        r5

                    else
                        let
                            r6 =
                                jfalse src o
                        in
                        if r6.ok || r6.c then
                            r6

                        else
                            let
                                r7 =
                                    jnull src o
                            in
                            if r7.ok then
                                r7

                            else
                                badJ r7.c


sepByValue : Vector Int -> Int -> R (Vector Json)
sepByValue src o =
    let
        r =
            value src o
    in
    if r.ok then
        sepByValueHelp src r.c (Vector.singleton r.v) r.o

    else if r.c then
        { ok = False, c = True, v = Vector.empty, o = 0 }

    else
        good False Vector.empty o


sepByValueHelp : Vector Int -> Bool -> Vector Json -> Int -> R (Vector Json)
sepByValueHelp src p acc o =
    let
        r1 =
            lexSym src o 44
    in
    if r1.ok then
        let
            r2 =
                value src r1.o
        in
        if r2.ok then
            sepByValueHelp src (p || (r1.c || r2.c)) (Vector.push r2.v acc) r2.o

        else if r1.c || r2.c then
            { ok = False, c = True, v = Vector.empty, o = 0 }

        else
            good p acc o

    else if r1.c then
        { ok = False, c = True, v = Vector.empty, o = 0 }

    else
        good p acc o


sepByMember : Vector Int -> Int -> R (Vector ( Vector Int, Json ))
sepByMember src o =
    let
        r =
            member src o
    in
    if r.ok then
        sepByMemberHelp src r.c (Vector.singleton r.v) r.o

    else if r.c then
        { ok = False, c = True, v = Vector.empty, o = 0 }

    else
        good False Vector.empty o


sepByMemberHelp : Vector Int -> Bool -> Vector ( Vector Int, Json ) -> Int -> R (Vector ( Vector Int, Json ))
sepByMemberHelp src p acc o =
    let
        r1 =
            lexSym src o 44
    in
    if r1.ok then
        let
            r2 =
                member src r1.o
        in
        if r2.ok then
            sepByMemberHelp src (p || (r1.c || r2.c)) (Vector.push r2.v acc) r2.o

        else if r1.c || r2.c then
            { ok = False, c = True, v = Vector.empty, o = 0 }

        else
            good p acc o

    else if r1.c then
        { ok = False, c = True, v = Vector.empty, o = 0 }

    else
        good p acc o


parseDocument : Vector Int -> Result String Json
parseDocument src =
    let
        r1 =
            spaces src 0

        r2 =
            value src r1.o
    in
    if r2.ok && r2.o == Vector.length src then
        Ok r2.v

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
