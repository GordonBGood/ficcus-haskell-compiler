module Main exposing (main)

import Dict
import Set
import Vector exposing (Vector)
import Int8 exposing (Int8)
import Word8 exposing (Word8)
import Word16 exposing (Word16)
import Word64 exposing (Word64)
import Float32 exposing (Float32)

logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items



bigger : comparable -> comparable -> comparable
bigger a b =
    if a > b then
        a

    else
        b


sum2 : number -> number -> number
sum2 a b =
    a + b


scale : Int8 -> List Int8 -> List Int8
scale k xs =
    List.map (\x -> x * k) xs


vec : Vector Word8
vec =
    Vector.fromList [ 250, 3, 7 ]


type alias Sample =
    { weight : Float32, id : Word64, tag : Int8 }


samples : List Sample
samples =
    [ { weight = Float32.fromFloat 1.5, id = 2, tag = 1 }, { weight = Float32.fromFloat 2.25, id = 3, tag = -1 } ]


samples2 : List Sample
samples2 =
    List.map identity samples

main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        logAll
                            [ String.join "," (List.map Word8.toString (Vector.toList (Vector.push 255 vec)))
                            , Debug.toString (Vector.get 1 vec)
                            , Word8.toString (Vector.foldl (+) 0 vec)
                            , String.join "," (List.map Word8.toString (Vector.toList (Vector.map (\x -> x + 10) vec)))
                            , Debug.toString vec
                            , Debug.toString (Vector.set 0 (Word8.fromInt 9) vec == Vector.fromList [ 9, 3, 7 ])
                            , String.join "," (List.map Int8.toString (scale 100 [ 1, 2, 3 ]))
                            , Word64.toString (bigger Word64.maxValue 5)
                            , Word64.toString (bigger 5 (Word64.fromInt -3))
                            , Int8.toString (bigger -3 -5)
                            , Word16.toString (sum2 65535 2)
                            , Int8.toString (sum2 127 1)
                            , String.fromInt (sum2 1 2)
                            , String.fromFloat (sum2 1.5 2)
                            , Float32.toString (sum2 (Float32.fromFloat 0.1) (Float32.fromFloat 0.2))
                            , Float32.toString (max (Float32.fromFloat 0.5) 2)
                            , Float32.toString (min (Float32.fromFloat 0.5) 2)
                            , String.join " " (List.map Float32.toString (List.sort [ Float32.fromFloat 0.5, 2, -1, Float32.fromFloat 0.25 ]))
                            , Debug.toString { weight = Float32.fromFloat 0.1, id = Word64.maxValue, tag = Int8.fromInt -1 }
                            , Debug.toString (samples == samples2)
                            , Word64.toString (List.foldl (\sm acc -> acc + sm.id) 0 samples)
                            , Float32.toString (List.foldl (\sm acc -> acc + sm.weight) 0 samples)
                            ]

                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
