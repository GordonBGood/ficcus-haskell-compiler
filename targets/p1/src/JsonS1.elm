module JsonS1 exposing (main)

{-| H16a, state S1: version A2 (JsonCombV.elm) with every combinator application expanded at its use into a named, specialized function
(no library closure remains: map, map2, andThen, keep, ignore, oneOf, lazy, loop, chomp*, symbol, word and the sepBy step are written
out; `succeed` and the `\_ f -> f` lambdas are gone). `Parser a` is still `State -> Step a` with the heap `Step` type; the `Loop` type of
the string loop is still built. The only function values left are the recursive rules passed to `sepBy` (`value`, `member`: static
closures of global functions). Same tree (JsonTreeV), same checksum as A2. The flags and results are exactly those of the library code.
-}

import JsonConfig
import JsonGen
import JsonTreeV as JsonTree exposing (Json(..))
import Vector exposing (Vector)


type alias State =
    { src : Vector Int, offset : Int }


type Step a
    = Good Bool a State
    | Bad Bool String


type Loop a
    = More
    | Done a


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



-- PRIMITIVES


symbol : Int -> State -> Step ()
symbol code s =
    if byteAt s.offset s.src == code then
        Good True () { s | offset = s.offset + 1 }

    else
        Bad False "symbol"


wordHelp : List Int -> Int -> State -> Step ()
wordHelp codes start s =
    case codes of
        [] ->
            Good True () s

        c :: rest ->
            if byteAt s.offset s.src == c then
                wordHelp rest start { s | offset = s.offset + 1 }

            else
                Bad (s.offset > start) "word"


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


spaces : State -> Step ()
spaces s =
    let
        o =
            chompWhileSpace s.src s.offset
    in
    Good (o > s.offset) () { s | offset = o }


{-| lexeme (symbol code) = ignore (symbol code) spaces
-}
lexSym : Int -> State -> Step ()
lexSym code s =
    case symbol code s of
        Bad c m ->
            Bad c m

        Good c1 _ s1 ->
            case spaces s1 of
                Bad c2 m ->
                    Bad (c1 || c2) m

                Good c2 _ s2 ->
                    Good (c1 || c2) () s2


{-| lexeme (word codes) = ignore (word codes) spaces
-}
lexWord : List Int -> State -> Step ()
lexWord codes s =
    case wordHelp codes s.offset s of
        Bad c m ->
            Bad c m

        Good c1 _ s1 ->
            case spaces s1 of
                Bad c2 m ->
                    Bad (c1 || c2) m

                Good c2 _ s2 ->
                    Good (c1 || c2) () s2


int10 : State -> Step Int
int10 s =
    let
        o =
            chompWhileDigit s.src s.offset
    in
    if o > s.offset then
        Good True (digitsValue s.src s.offset o 0) { s | offset = o }

    else
        Bad False "digit"


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



-- NUMBERS (number = map2 applySign minus unsignedNumber, ...)


minus : State -> Step Bool
minus s =
    case symbol 45 s of
        Good c _ s1 ->
            Good c True s1

        Bad c m ->
            if c then
                Bad c m

            else
                Good False False s


number : State -> Step Float
number s =
    case minus s of
        Bad c m ->
            Bad c m

        Good c1 neg s1 ->
            case unsignedNumber s1 of
                Bad c2 m ->
                    Bad (c1 || c2) m

                Good c2 x s2 ->
                    Good (c1 || c2) (applySign neg x) s2


unsignedNumber : State -> Step Float
unsignedNumber s =
    case int10 s of
        Bad c m ->
            Bad c m

        Good c1 ip s1 ->
            case fraction s1 of
                Bad c2 m ->
                    Bad (c1 || c2) m

                Good c2 fr s2 ->
                    case exponent s2 of
                        Bad c3 m ->
                            Bad (c1 || (c2 || c3)) m

                        Good c3 ex s3 ->
                            Good (c1 || (c2 || c3)) ((toFloat ip + fr) * ex) s3


fraction : State -> Step Float
fraction s =
    case symbol 46 s of
        Good c1 _ s1 ->
            case fractionDigits s1 of
                Good c2 v s2 ->
                    Good (c1 || c2) v s2

                Bad c2 m ->
                    if c1 || c2 then
                        Bad (c1 || c2) m

                    else
                        Good False 0 s

        Bad c m ->
            if c then
                Bad c m

            else
                Good False 0 s


fractionDigits : State -> Step Float
fractionDigits s =
    case int10 s of
        Bad c m ->
            Bad c m

        Good c v s1 ->
            Good c (toFloat v / pow10 (s1.offset - s.offset)) s1


exponent : State -> Step Float
exponent s =
    case exponentMark s of
        Good c1 _ s1 ->
            case exponentBody s1 of
                Good c2 e s2 ->
                    Good (c1 || c2) e s2

                Bad c2 m ->
                    if c1 || c2 then
                        Bad (c1 || c2) m

                    else
                        Good False 1 s

        Bad c m ->
            if c then
                Bad c m

            else
                Good False 1 s


exponentMark : State -> Step ()
exponentMark s =
    case symbol 101 s of
        Good c a s1 ->
            Good c a s1

        Bad c m ->
            if c then
                Bad c m

            else
                case symbol 69 s of
                    Good c2 a s1 ->
                        Good c2 a s1

                    Bad c2 m2 ->
                        if c2 then
                            Bad c2 m2

                        else
                            Bad False "oneOf"


exponentBody : State -> Step Float
exponentBody s =
    case exponentSign s of
        Bad c m ->
            Bad c m

        Good c1 neg s1 ->
            case int10 s1 of
                Bad c2 m ->
                    Bad (c1 || c2) m

                Good c2 e s2 ->
                    Good (c1 || c2) (exponentFactor neg e) s2


exponentSign : State -> Step Bool
exponentSign s =
    case symbol 43 s of
        Good c _ s1 ->
            Good c False s1

        Bad c m ->
            if c then
                Bad c m

            else
                case symbol 45 s of
                    Good c2 _ s1 ->
                        Good c2 True s1

                    Bad c2 m2 ->
                        if c2 then
                            Bad c2 m2

                        else
                            Good False False s



-- STRINGS


stringToken : State -> Step (Vector Int)
stringToken s =
    case symbol 34 s of
        Bad c m ->
            Bad c m

        Good c1 _ s1 ->
            case stringChomped s1 of
                Bad c2 m ->
                    Bad (c1 || c2) m

                Good c2 raw s2 ->
                    case lexSym 34 s2 of
                        Bad c3 m ->
                            Bad ((c1 || c2) || c3) m

                        Good c3 _ s3 ->
                            Good ((c1 || c2) || c3) (unescape raw) s3


stringChomped : State -> Step (Vector Int)
stringChomped s =
    case stringBody False s of
        Good c _ s1 ->
            Good c (Vector.slice s.offset s1.offset s.src) s1

        Bad c m ->
            Bad c m


{-| loop () (\_ -> oneOf [ map (\_ -> More ()) stringChunk, succeed (Done ()) ])
-}
stringBody : Bool -> State -> Step ()
stringBody p s =
    case stringStep s of
        Good c step s1 ->
            case step of
                More ->
                    stringBody (p || c) s1

                Done a ->
                    Good (p || c) a s1

        Bad c m ->
            Bad (p || c) m


stringStep : State -> Step (Loop ())
stringStep s =
    case stringChunk s of
        Good c _ s1 ->
            Good c More s1

        Bad c m ->
            if c then
                Bad c m

            else
                Good False (Done ()) s


stringChunk : State -> Step ()
stringChunk s =
    case chompSomePlain s of
        Good c a s1 ->
            Good c a s1

        Bad c m ->
            if c then
                Bad c m

            else
                case escape s of
                    Good c2 a s1 ->
                        Good c2 a s1

                    Bad c2 m2 ->
                        if c2 then
                            Bad c2 m2

                        else
                            Bad False "oneOf"


chompSomePlain : State -> Step ()
chompSomePlain s =
    let
        b =
            byteAt s.offset s.src
    in
    if b >= 0 && isPlain b then
        Good True () { s | offset = chompWhilePlain s.src (s.offset + 1) }

    else
        Bad False "chompIf"


escape : State -> Step ()
escape s =
    case symbol 92 s of
        Bad c m ->
            Bad c m

        Good c1 _ s1 ->
            if byteAt s1.offset s1.src >= 0 then
                Good True () { s1 | offset = s1.offset + 1 }

            else
                Bad c1 "chompIf"



-- THE GRAMMAR


jnull : State -> Step Json
jnull s =
    case lexWord nullWord s of
        Good c _ s1 ->
            Good c JNull s1

        Bad c m ->
            Bad c m


jtrue : State -> Step Json
jtrue s =
    case lexWord trueWord s of
        Good c _ s1 ->
            Good c (JBool True) s1

        Bad c m ->
            Bad c m


jfalse : State -> Step Json
jfalse s =
    case lexWord falseWord s of
        Good c _ s1 ->
            Good c (JBool False) s1

        Bad c m ->
            Bad c m


jnumber : State -> Step Json
jnumber s =
    case number s of
        Bad c m ->
            Bad c m

        Good c1 x s1 ->
            case spaces s1 of
                Bad c2 m ->
                    Bad (c1 || c2) m

                Good c2 _ s2 ->
                    Good (c1 || c2) (JNum x) s2


jstring : State -> Step Json
jstring s =
    case stringToken s of
        Good c v s1 ->
            Good c (JStr v) s1

        Bad c m ->
            Bad c m


jarray : State -> Step Json
jarray s =
    case lexSym 91 s of
        Bad c m ->
            Bad c m

        Good c1 _ s1 ->
            case sepBy value s1 of
                Bad c2 m ->
                    Bad (c1 || c2) m

                Good c2 xs s2 ->
                    case lexSym 93 s2 of
                        Bad c3 m ->
                            Bad ((c1 || c2) || c3) m

                        Good c3 _ s3 ->
                            Good ((c1 || c2) || c3) (JArr xs) s3


jobject : State -> Step Json
jobject s =
    case lexSym 123 s of
        Bad c m ->
            Bad c m

        Good c1 _ s1 ->
            case sepBy member s1 of
                Bad c2 m ->
                    Bad (c1 || c2) m

                Good c2 xs s2 ->
                    case lexSym 125 s2 of
                        Bad c3 m ->
                            Bad ((c1 || c2) || c3) m

                        Good c3 _ s3 ->
                            Good ((c1 || c2) || c3) (JObj xs) s3


member : State -> Step ( Vector Int, Json )
member s =
    case stringToken s of
        Bad c m ->
            Bad c m

        Good c1 k s1 ->
            case lexSym 58 s1 of
                Bad c2 m ->
                    Bad (c1 || c2) m

                Good c2 _ s2 ->
                    case value s2 of
                        Bad c3 m ->
                            Bad (c1 || (c2 || c3)) m

                        Good c3 v s3 ->
                            Good (c1 || (c2 || c3)) ( k, v ) s3


{-| oneOf [ jarray (), jobject (), jstring, jnumber, jtrue, jfalse, jnull ] under lazy
-}
value : State -> Step Json
value s =
    case jarray s of
        Good c a s1 ->
            Good c a s1

        Bad c m ->
            if c then
                Bad c m

            else
                case jobject s of
                    Good c2 a s1 ->
                        Good c2 a s1

                    Bad c2 m2 ->
                        if c2 then
                            Bad c2 m2

                        else
                            case jstring s of
                                Good c3 a s1 ->
                                    Good c3 a s1

                                Bad c3 m3 ->
                                    if c3 then
                                        Bad c3 m3

                                    else
                                        case jnumber s of
                                            Good c4 a s1 ->
                                                Good c4 a s1

                                            Bad c4 m4 ->
                                                if c4 then
                                                    Bad c4 m4

                                                else
                                                    case jtrue s of
                                                        Good c5 a s1 ->
                                                            Good c5 a s1

                                                        Bad c5 m5 ->
                                                            if c5 then
                                                                Bad c5 m5

                                                            else
                                                                case jfalse s of
                                                                    Good c6 a s1 ->
                                                                        Good c6 a s1

                                                                    Bad c6 m6 ->
                                                                        if c6 then
                                                                            Bad c6 m6

                                                                        else
                                                                            case jnull s of
                                                                                Good c7 a s1 ->
                                                                                    Good c7 a s1

                                                                                Bad c7 m7 ->
                                                                                    if c7 then
                                                                                        Bad c7 m7

                                                                                    else
                                                                                        Bad False "oneOf"


{-| sepBy item (lexeme (symbol 44)) with the step `keep (map (\_ y -> y) sep) item` written out; `item` is a recursive rule
-}
sepBy : (State -> Step a) -> State -> Step (Vector a)
sepBy item s =
    case item s of
        Bad c m ->
            if c then
                Bad c m

            else
                Good False Vector.empty s

        Good c1 x s1 ->
            sepByHelp item c1 (Vector.singleton x) s1


sepByHelp : (State -> Step a) -> Bool -> Vector a -> State -> Step (Vector a)
sepByHelp item p acc s =
    case lexSym 44 s of
        Bad c m ->
            if c then
                Bad c m

            else
                Good p acc s

        Good c1 _ s1 ->
            case item s1 of
                Bad c2 m ->
                    if c1 || c2 then
                        Bad (c1 || c2) m

                    else
                        Good p acc s

                Good c2 y s2 ->
                    sepByHelp item (p || (c1 || c2)) (Vector.push y acc) s2


{-| document = ignore (keep (ignore (succeed identity) spaces) value) endOfInput
-}
parseDocument : Vector Int -> Result String Json
parseDocument src =
    case spaces { src = src, offset = 0 } of
        Bad _ m ->
            Err m

        Good _ _ s1 ->
            case value s1 of
                Bad _ m ->
                    Err m

                Good _ v s2 ->
                    if s2.offset == Vector.length s2.src then
                        Ok v

                    else
                        Err "end of input"





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
