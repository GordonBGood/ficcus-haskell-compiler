module JsonStrComb exposing (main)

{-| P1, version A on a String (1 MB only): the same JSON parser as JsonComb.elm, but the source is a `String` and a byte is read with
`String.slice i (i + 1)`, which on the C path costs O(i) (elm/parser has a kernel with an offset cache for this; user code has not). Cost of
String handling on its own. A parser built from a small parser combinator library modelled on elm/parser.

The recursive grammar rules `jarray`, `jobject` and `member` are functions of `()`: a cycle of top-level values through `lazy`
(value -> jarray -> value) is initialised in the wrong order on the C path (segmentation fault at start up; see docs/P1-JSON.md).

Differences from elm/parser (docs/P1-JSON.md): the source is a `String` of byte values (the text is ASCII; non-ASCII
characters occur only as \u escapes), predicates work on Int byte codes, a parser is a plain function (a type alias, not a
wrapper), the state is `{ src, offset }` (no row, column, indent, context), `keep` and `ignore` are named functions, a
problem is a String.

Stage (JsonConfig.stage): 0 generate the text, 1 also convert it to a String, 2 also parse it and print the checksum.
-}

import JsonConfig
import JsonGen
import JsonTree exposing (Json(..))



-- THE COMBINATOR LIBRARY


type alias State =
    { src : String, offset : Int }


type Step a
    = Good Bool a State
    | Bad Bool String


type alias Parser a =
    State -> Step a


type Loop state a
    = More state
    | Done a


succeed : a -> Parser a
succeed a =
    \s -> Good False a s


problem : String -> Parser a
problem msg =
    \_ -> Bad False msg


map : (a -> b) -> Parser a -> Parser b
map f p =
    \s ->
        case p s of
            Good c a s1 ->
                Good c (f a) s1

            Bad c m ->
                Bad c m


map2 : (a -> b -> c) -> Parser a -> Parser b -> Parser c
map2 f pa pb =
    \s ->
        case pa s of
            Bad c m ->
                Bad c m

            Good c1 a s1 ->
                case pb s1 of
                    Bad c2 m ->
                        Bad (c1 || c2) m

                    Good c2 b s2 ->
                        Good (c1 || c2) (f a b) s2


andThen : (a -> Parser b) -> Parser a -> Parser b
andThen f pa =
    \s ->
        case pa s of
            Bad c m ->
                Bad c m

            Good c1 a s1 ->
                case f a s1 of
                    Bad c2 m ->
                        Bad (c1 || c2) m

                    Good c2 b s2 ->
                        Good (c1 || c2) b s2


keep : Parser (a -> b) -> Parser a -> Parser b
keep pf pa =
    map2 (\f a -> f a) pf pa


ignore : Parser keep -> Parser skip -> Parser keep
ignore pk ps =
    map2 (\k _ -> k) pk ps


oneOf : List (Parser a) -> Parser a
oneOf ps =
    \s -> oneOfHelp s ps


oneOfHelp : State -> List (Parser a) -> Step a
oneOfHelp s ps =
    case ps of
        [] ->
            Bad False "oneOf"

        p :: rest ->
            case p s of
                Good c a s1 ->
                    Good c a s1

                Bad c m ->
                    if c then
                        Bad c m

                    else
                        oneOfHelp s rest


lazy : (() -> Parser a) -> Parser a
lazy thunk =
    \s -> thunk () s


loop : state -> (state -> Parser (Loop state a)) -> Parser a
loop st f =
    \s -> loopHelp False st f s


loopHelp : Bool -> state -> (state -> Parser (Loop state a)) -> State -> Step a
loopHelp p st f s =
    case f st s of
        Good c step s1 ->
            case step of
                More st1 ->
                    loopHelp (p || c) st1 f s1

                Done a ->
                    Good (p || c) a s1

        Bad c m ->
            Bad (p || c) m



-- PRIMITIVES (they read the source)


byteAt : Int -> String -> Int
byteAt i src =
    case String.uncons (String.slice i (i + 1) src) of
        Just ( c, _ ) ->
            Char.toCode c

        Nothing ->
            -1


symbol : Int -> Parser ()
symbol code =
    \s ->
        if byteAt s.offset s.src == code then
            Good True () { s | offset = s.offset + 1 }

        else
            Bad False "symbol"


word : List Int -> Parser ()
word codes =
    \s -> wordHelp codes s.offset s


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


chompIf : (Int -> Bool) -> Parser ()
chompIf isGood =
    \s ->
        let
            b =
                byteAt s.offset s.src
        in
        if b >= 0 && isGood b then
            Good True () { s | offset = s.offset + 1 }

        else
            Bad False "chompIf"


chompWhile : (Int -> Bool) -> Parser ()
chompWhile isGood =
    \s ->
        let
            o =
                chompWhileHelp isGood s.src s.offset
        in
        Good (o > s.offset) () { s | offset = o }


chompWhileHelp : (Int -> Bool) -> String -> Int -> Int
chompWhileHelp isGood src o =
    let
        b =
            byteAt o src
    in
    if b >= 0 && isGood b then
        chompWhileHelp isGood src (o + 1)

    else
        o


chompSome : (Int -> Bool) -> Parser ()
chompSome isGood =
    ignore (chompIf isGood) (chompWhile isGood)


getOffset : Parser Int
getOffset =
    \s -> Good False s.offset s


getChompedString : Parser a -> Parser String
getChompedString p =
    \s ->
        case p s of
            Good c _ s1 ->
                Good c (bytesToString s.offset s1.offset s.src) s1

            Bad c m ->
                Bad c m


bytesToString : Int -> Int -> String -> String
bytesToString from to src =
    String.slice from to src


{-| the value of one or more decimal digits (fails without consuming when there is none)
-}
int10 : Parser Int
int10 =
    \s ->
        let
            o =
                chompWhileHelp isDigit s.src s.offset
        in
        if o > s.offset then
            Good True (digitsValue s.src s.offset o 0) { s | offset = o }

        else
            Bad False "digit"


digitsValue : String -> Int -> Int -> Int -> Int
digitsValue src i end acc =
    if i >= end then
        acc

    else
        digitsValue src (i + 1) end (acc * 10 + byteAt i src - 48)


number : Parser Float
number =
    map2 (\neg x -> applySign neg x) minus unsignedNumber


applySign : Bool -> Float -> Float
applySign neg x =
    if neg then
        negate x

    else
        x


minus : Parser Bool
minus =
    oneOf [ map (\_ -> True) (symbol 45), succeed False ]


unsignedNumber : Parser Float
unsignedNumber =
    andThen
        (\ip -> andThen (\fr -> map (\ex -> (toFloat ip + fr) * ex) exponent) fraction)
        int10


fraction : Parser Float
fraction =
    oneOf
        [ keep (map (\_ f -> f) (symbol 46)) fractionDigits
        , succeed 0
        ]


fractionDigits : Parser Float
fractionDigits =
    andThen
        (\o0 -> andThen (\v -> map (\o1 -> toFloat v / pow10 (o1 - o0)) getOffset) int10)
        getOffset


exponent : Parser Float
exponent =
    oneOf
        [ keep (map (\_ e -> e) (oneOf [ symbol 101, symbol 69 ])) exponentBody
        , succeed 1
        ]


exponentBody : Parser Float
exponentBody =
    andThen
        (\neg -> map (\e -> exponentFactor neg e) int10)
        (oneOf [ map (\_ -> False) (symbol 43), map (\_ -> True) (symbol 45), succeed False ])


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



-- THE JSON GRAMMAR


isDigit : Int -> Bool
isDigit b =
    b >= 48 && b <= 57


isSpace : Int -> Bool
isSpace b =
    b == 32 || b == 10 || b == 13 || b == 9


isPlain : Int -> Bool
isPlain b =
    b /= 34 && b /= 92


spaces : Parser ()
spaces =
    chompWhile isSpace


lexeme : Parser a -> Parser a
lexeme p =
    ignore p spaces


nullWord : List Int
nullWord =
    [ 110, 117, 108, 108 ]


trueWord : List Int
trueWord =
    [ 116, 114, 117, 101 ]


falseWord : List Int
falseWord =
    [ 102, 97, 108, 115, 101 ]


value : Parser Json
value =
    lazy (\_ -> oneOf [ jarray (), jobject (), jstring, jnumber, jtrue, jfalse, jnull ])


jnull : Parser Json
jnull =
    map (\_ -> JNull) (lexeme (word nullWord))


jtrue : Parser Json
jtrue =
    map (\_ -> JBool True) (lexeme (word trueWord))


jfalse : Parser Json
jfalse =
    map (\_ -> JBool False) (lexeme (word falseWord))


jnumber : Parser Json
jnumber =
    map JNum (lexeme number)


jstring : Parser Json
jstring =
    map JStr stringToken


stringToken : Parser String
stringToken =
    ignore
        (keep (ignore (succeed unescape) (symbol 34)) (getChompedString stringBody))
        (lexeme (symbol 34))


stringBody : Parser ()
stringBody =
    loop () (\_ -> oneOf [ map (\_ -> More ()) stringChunk, succeed (Done ()) ])


stringChunk : Parser ()
stringChunk =
    oneOf [ chompSome isPlain, ignore (symbol 92) (chompIf (\_ -> True)) ]


jarray : () -> Parser Json
jarray _ =
    ignore
        (keep (ignore (succeed JArr) (lexeme (symbol 91))) (sepBy value (lexeme (symbol 44))))
        (lexeme (symbol 93))


jobject : () -> Parser Json
jobject _ =
    ignore
        (keep (ignore (succeed JObj) (lexeme (symbol 123))) (sepBy (member ()) (lexeme (symbol 44))))
        (lexeme (symbol 125))


member : () -> Parser ( String, Json )
member _ =
    map2 (\k v -> ( k, v )) stringToken (keep (map (\_ v -> v) (lexeme (symbol 58))) value)


sepBy : Parser a -> Parser () -> Parser (List a)
sepBy item sep =
    oneOf
        [ map List.reverse (andThen (\x -> loop [ x ] (sepByStep item sep)) item)
        , succeed []
        ]


sepByStep : Parser a -> Parser () -> List a -> Parser (Loop (List a) (List a))
sepByStep item sep acc =
    oneOf
        [ map (\y -> More (y :: acc)) (keep (map (\_ y -> y) sep) item)
        , succeed (Done acc)
        ]


endOfInput : Parser ()
endOfInput =
    \s ->
        if s.offset == String.length s.src then
            Good False () s

        else
            Bad False "end of input"


document : Parser Json
document =
    ignore (keep (ignore (succeed identity) spaces) value) endOfInput


run : Parser a -> String -> Result String a
run p src =
    case p { src = src, offset = 0 } of
        Good _ a _ ->
            Ok a

        Bad _ m ->
            Err m



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



-- MAIN


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
                            case run document text of
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
