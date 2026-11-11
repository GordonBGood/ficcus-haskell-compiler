module FicOverlayBytes exposing
    ( wrap, unwrap, failure
    , readI8, readU8, readI16, readU16, readI32, readU32, readF32, readF64, readBytes, readString
    , decode
    , signedInt8, signedInt16, signedInt32, unsignedInt8, unsignedInt16, unsignedInt32, float32, float64
    , bytes, string
    , map, map2, map3, map4, map5, andThen, succeed, fail, loop
    )

{-| Ficcus: `Bytes.Decode` of elm/bytes without exceptions. In Elm a read beyond the end of the bytes and `fail` throw a JavaScript
exception that `decode` catches. Here a decoder is still a function `Bytes -> Int -> ( Int, a )`, but a failure is the offset `-1`
with a placeholder value that is never looked at: every combinator below tests the offset before it uses the value, so a failed
decode ends normally and frees what it built. Compiled only into projects that depend directly on elm/bytes
(Ficcus.Mono.Overlay); the specializer redirects every function of `Bytes.Decode` to the function of the same name here.

The definitions of the first two sections only give the types: they are kernel functions (`author/project:FicOverlayBytes.<name>`
in Ficcus.Mono.Kernel, runtime/fic_bytes.h), their bodies are never compiled to C.

-}

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode exposing (Decoder, Step(..))



-- KERNEL FUNCTIONS (types only)


{-| the constructor `Decoder` of `Bytes.Decode` (not exported by the package)
-}
wrap : (Bytes -> Int -> ( Int, a )) -> Decoder a
wrap f =
    wrap f


{-| the function of a decoder
-}
unwrap : Decoder a -> (Bytes -> Int -> ( Int, a ))
unwrap decoder =
    unwrap decoder


{-| the failed result: offset -1 and a placeholder
-}
failure : () -> ( Int, a )
failure u =
    failure u


readI8 : Bytes -> Int -> ( Int, Int )
readI8 _ offset =
    ( offset, 0 )


readU8 : Bytes -> Int -> ( Int, Int )
readU8 _ offset =
    ( offset, 0 )


{-| the first argument: little endian
-}
readI16 : Bool -> Bytes -> Int -> ( Int, Int )
readI16 _ _ offset =
    ( offset, 0 )


readU16 : Bool -> Bytes -> Int -> ( Int, Int )
readU16 _ _ offset =
    ( offset, 0 )


readI32 : Bool -> Bytes -> Int -> ( Int, Int )
readI32 _ _ offset =
    ( offset, 0 )


readU32 : Bool -> Bytes -> Int -> ( Int, Int )
readU32 _ _ offset =
    ( offset, 0 )


readF32 : Bool -> Bytes -> Int -> ( Int, Float )
readF32 _ _ offset =
    ( offset, 0 )


readF64 : Bool -> Bytes -> Int -> ( Int, Float )
readF64 _ _ offset =
    ( offset, 0 )


{-| the first argument: the number of bytes
-}
readBytes : Int -> Bytes -> Int -> ( Int, Bytes )
readBytes _ bites offset =
    ( offset, bites )


readString : Int -> Bytes -> Int -> ( Int, String )
readString _ _ offset =
    ( offset, "" )



-- BYTES.DECODE


decode : Decoder a -> Bytes -> Maybe a
decode decoder bs =
    let
        run =
            unwrap decoder

        ( offset, a ) =
            run bs 0
    in
    if offset < 0 then
        Nothing

    else
        Just a


signedInt8 : Decoder Int
signedInt8 =
    wrap readI8


signedInt16 : Endianness -> Decoder Int
signedInt16 endianness =
    wrap (readI16 (endianness == LE))


signedInt32 : Endianness -> Decoder Int
signedInt32 endianness =
    wrap (readI32 (endianness == LE))


unsignedInt8 : Decoder Int
unsignedInt8 =
    wrap readU8


unsignedInt16 : Endianness -> Decoder Int
unsignedInt16 endianness =
    wrap (readU16 (endianness == LE))


unsignedInt32 : Endianness -> Decoder Int
unsignedInt32 endianness =
    wrap (readU32 (endianness == LE))


float32 : Endianness -> Decoder Float
float32 endianness =
    wrap (readF32 (endianness == LE))


float64 : Endianness -> Decoder Float
float64 endianness =
    wrap (readF64 (endianness == LE))


bytes : Int -> Decoder Bytes
bytes n =
    wrap (readBytes n)


string : Int -> Decoder String
string n =
    wrap (readString n)


map : (a -> b) -> Decoder a -> Decoder b
map func decoderA =
    let
        decodeA =
            unwrap decoderA
    in
    wrap
        (\bites offset ->
            let
                ( aOffset, a ) =
                    decodeA bites offset
            in
            if aOffset < 0 then
                failure ()

            else
                ( aOffset, func a )
        )


map2 : (a -> b -> result) -> Decoder a -> Decoder b -> Decoder result
map2 func decoderA decoderB =
    let
        decodeA =
            unwrap decoderA

        decodeB =
            unwrap decoderB
    in
    wrap
        (\bites offset ->
            let
                ( aOffset, a ) =
                    decodeA bites offset
            in
            if aOffset < 0 then
                failure ()

            else
                let
                    ( bOffset, b ) =
                        decodeB bites aOffset
                in
                if bOffset < 0 then
                    failure ()

                else
                    ( bOffset, func a b )
        )


map3 : (a -> b -> c -> result) -> Decoder a -> Decoder b -> Decoder c -> Decoder result
map3 func decoderA decoderB decoderC =
    map2 (<|) (map2 func decoderA decoderB) decoderC


map4 : (a -> b -> c -> d -> result) -> Decoder a -> Decoder b -> Decoder c -> Decoder d -> Decoder result
map4 func decoderA decoderB decoderC decoderD =
    map2 (<|) (map3 func decoderA decoderB decoderC) decoderD


map5 : (a -> b -> c -> d -> e -> result) -> Decoder a -> Decoder b -> Decoder c -> Decoder d -> Decoder e -> Decoder result
map5 func decoderA decoderB decoderC decoderD decoderE =
    map2 (<|) (map4 func decoderA decoderB decoderC decoderD) decoderE


andThen : (a -> Decoder b) -> Decoder a -> Decoder b
andThen callback decoderA =
    let
        decodeA =
            unwrap decoderA
    in
    wrap
        (\bites offset ->
            let
                ( newOffset, a ) =
                    decodeA bites offset
            in
            if newOffset < 0 then
                failure ()

            else
                let
                    decodeB =
                        unwrap (callback a)
                in
                decodeB bites newOffset
        )


succeed : a -> Decoder a
succeed a =
    wrap (\_ offset -> ( offset, a ))


fail : Decoder a
fail =
    wrap (\_ _ -> failure ())


loop : state -> (state -> Decoder (Step state a)) -> Decoder a
loop state callback =
    wrap (loopHelp state callback)


loopHelp : state -> (state -> Decoder (Step state a)) -> Bytes -> Int -> ( Int, a )
loopHelp state callback bites offset =
    let
        decoder =
            unwrap (callback state)

        ( newOffset, step ) =
            decoder bites offset
    in
    if newOffset < 0 then
        failure ()

    else
        case step of
            Loop newState ->
                loopHelp newState callback bites newOffset

            Done result ->
                ( newOffset, result )
