module Main exposing (main)

import Dict
import Set
import Int8 exposing (Int8)
import Int16 exposing (Int16)
import Int32 exposing (Int32)
import Word8 exposing (Word8)
import Word16 exposing (Word16)
import Word32 exposing (Word32)
import Word64 exposing (Word64)
import Float32 exposing (Float32)

logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items



a : Int8
a =
    127


b : Int8
b =
    -128


c : Word8
c =
    255


d : Word16
d =
    0xFFFF


e : Word64
e =
    9223372036854775807


f : Int32
f =
    -2147483648


g : Float32
g =
    16777217


h : Float32
h =
    3


i : Word32
i =
    4294967295


j : Int16
j =
    -32768


k : Float32
k =
    -5


big : Float32
big =
    123456789123


classify : Int8 -> String
classify x =
    if x == 0 then
        "zero"

    else if x == 1 then
        "one"

    else if x == -1 then
        "minus one"

    else if x == 127 then
        "max"

    else
        "other"


classifyW : Word8 -> String
classifyW x =
    if x == 255 then
        "max"

    else if x == 0 then
        "zero"

    else
        "other"


bytes : List Word8
bytes =
    [ 0, 1, 255 ]


type alias Pixel =
    { r : Word8, g : Word8, b : Word8 }


px : Pixel
px =
    { r = 255, g = 128, b = 0 }


twice : number -> number
twice x =
    x + x


inc : Int8 -> Int8
inc x =
    x + 1

main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        logAll
                            [ Int8.toString a
                            , Int8.toString b
                            , Word8.toString c
                            , Word16.toString d
                            , Word64.toString e
                            , Int32.toString f
                            , Float32.toString g
                            , Float32.toString h
                            , Word32.toString i
                            , Int16.toString j
                            , Float32.toString k
                            , Float32.toString big
                            , classify 0
                            , classify 1
                            , classify -1
                            , classify 127
                            , classify (Int8.fromInt 300)
                            , classifyW 255
                            , classifyW (Word8.fromInt -256)
                            , classifyW 7
                            , String.join "," (List.map Word8.toString bytes)
                            , String.join "," (List.map Word8.toString [ px.r, px.g, px.b ])
                            , Int8.toString (twice 60)
                            , Int8.toString (twice 100)
                            , Word8.toString (twice 200)
                            , Int8.toString (inc 127)
                            , Int8.toString (inc (inc 126))
                            , Debug.toString (a == 127)
                            , Debug.toString (c > 254)
                            , Debug.toString (px == { r = 255, g = 128, b = 0 })
                            , Debug.toString px
                            , Word8.toString (c + 1)
                            , Word8.toString (0 - 1)
                            , Word64.toString (0 - 1)
                            , Int8.toString (-b)
                            , Int8.toString (abs b)
                            , Word8.toString (negate c)
                            ]

                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
