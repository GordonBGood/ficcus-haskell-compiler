module Main exposing (main)

import Dict
import Set
import Int8 exposing (Int8)
import Int16 exposing (Int16)
import Int32 exposing (Int32)
import Int64 exposing (Int64)
import Word8 exposing (Word8)
import Word16 exposing (Word16)
import Word32 exposing (Word32)
import Word64 exposing (Word64)
import Float32 exposing (Float32)
import Float64 exposing (Float64)

logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items



alias64 : Int64 -> Int
alias64 x =
    x


int1 : Int
int1 =
    1

main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        logAll
                            [ Int8.toString (Int8.fromInt 200)
                            , Int8.toString (Int8.fromInt -129)
                            , Word8.toString (Word8.fromInt -1)
                            , Word8.toString (Word8.fromInt 256)
                            , Int32.toString (Int32.fromInt 4294967295)
                            , String.fromInt (Word32.toInt (Word32.fromInt -1))
                            , String.fromInt (Word64.toInt Word64.maxValue)
                            , String.fromInt (Int16.toInt (Int16.fromInt 40000))
                            , Debug.toString (Int8.fromString "127")
                            , Debug.toString (Int8.fromString "128")
                            , Debug.toString (Int8.fromString "-128")
                            , Debug.toString (Int8.fromString "-129")
                            , Debug.toString (Int8.fromString "abc")
                            , Debug.toString (Int8.fromString "")
                            , Debug.toString (Word8.fromString "-1")
                            , Debug.toString (Word8.fromString "255")
                            , Debug.toString (Word8.fromString "256")
                            , Debug.toString (Word8.fromString "0")
                            , Debug.toString (Word64.fromString "18446744073709551615")
                            , Debug.toString (Word64.fromString "18446744073709551616")
                            , Debug.toString (Word64.fromString "9223372036854775808")
                            , Debug.toString (Word64.fromString "0")
                            , Debug.toString (Word64.fromString "-1")
                            , Debug.toString (Word64.fromString "")
                            , Debug.toString (Word64.fromString "12a")
                            , Debug.toString (Word64.fromString "99999999999999999999")
                            , Debug.toString (Float32.fromString "1.5")
                            , Debug.toString (Float32.fromString "x")
                            , Debug.toString (Float32.fromString "0.1")
                            , Float32.toString (Float32.fromFloat 1.0e40)
                            , Float32.toString (Float32.fromFloat -1.0e40)
                            , String.fromFloat (Float32.toFloat (Float32.fromFloat 0.1))
                            , Float32.toString (Float32.fromInt 16777217)
                            , Float32.toString (Float32.fromInt -3)
                            , Float32.toString (Float32.fromFloat 1.0e-46)
                            , String.fromInt (Int64.toInt (Int64.fromInt 7))
                            , String.fromInt (Int64.popCount -1)
                            , String.fromInt (Int64.popCount 0)
                            , Int64.toString (Int64.shiftLeftBy 63 1)
                            , Int64.toString (Int64.shiftLeftBy 64 1)
                            , Int64.toString (Int64.shiftRightBy 1 -8)
                            , Int64.toString (Int64.and 12 10)
                            , Int64.toString (Int64.xor 12 10)
                            , Int64.toString (Int64.complement 0)
                            , Int64.toString Int64.maxValue
                            , Int64.toString Int64.minValue
                            , Debug.toString (Int64.fromString "42")
                            , Int64.toString (alias64 5 + int1)
                            , String.fromInt (9223372036854775807 + 1)
                            , String.fromInt (3037000500 * 3037000500)
                            , String.fromInt ((0 - 9223372036854775807) - 2)
                            , String.fromInt (abs (0 - 9223372036854775807 - 1))
                            , String.fromInt (negate (0 - 9223372036854775807 - 1))
                            , String.fromInt ((0 - 9223372036854775807 - 1) // -1)
                            , String.fromInt (modBy -1 7)
                            , String.fromInt (5 // 0)
                            , String.fromInt (2 ^ 64)
                            , String.fromInt (3 ^ 41)
                            , String.fromFloat (Float64.toFloat 1.5)
                            , Float64.toString (Float64.fromInt 3)
                            , Debug.toString (Float64.fromString "2.5")
                            , Debug.toString ( Word64.maxValue, Float32.fromFloat 0.1, Int8.fromInt -5 )
                            , Debug.toString [ Word8.fromInt 1, Word8.fromInt 255 ]
                            ]

                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
