module Main exposing (main)

import Dict
import Set
import Int8 exposing (Int8)
import Int16 exposing (Int16)
import Int32 exposing (Int32)
import Word8 exposing (Word8)
import Word16 exposing (Word16)
import Word64 exposing (Word64)
import Float32 exposing (Float32)

logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items



w8 : List Word8
w8 =
    [ 200, 5, 255, 0, 128 ]


i8 : List Int8
i8 =
    [ 5, -3, 127, -128, 0 ]


w64 : List Word64
w64 =
    [ Word64.maxValue, 5, 9223372036854775807, Word64.fromInt -9223372036854775807 ]

main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        logAll
                            [ String.join " " (List.map Word8.toString (List.sort w8))
                            , String.join " " (List.map Int8.toString (List.sort i8))
                            , String.join " " (List.map Word64.toString (List.sort w64))
                            , String.join " " (List.map Word64.toString (List.reverse (List.sort w64)))
                            , String.join " " (List.map (\( k, v ) -> Word8.toString k ++ ":" ++ v) (Dict.toList (Dict.fromList [ ( 200, "a" ), ( 5, "b" ), ( 255, "c" ), ( 0, "d" ) ])))
                            , String.join " " (List.map (\( k, v ) -> Word64.toString k ++ ":" ++ v) (Dict.toList (Dict.fromList [ ( Word64.maxValue, "a" ), ( 5, "b" ), ( Word64.fromInt -9223372036854775807, "c" ) ])))
                            , String.join " " (List.map Int8.toString (Set.toList (Set.fromList [ 3, -1, 3, 127, -128 ])))
                            , Debug.toString (List.maximum w8)
                            , Debug.toString (List.minimum i8)
                            , Debug.toString (List.maximum w64)
                            , Int8.toString (clamp -10 10 (Int8.fromInt 50))
                            , Int8.toString (clamp -10 10 (Int8.fromInt -50))
                            , Word8.toString (max 200 (Word8.fromInt 255))
                            , Word8.toString (min 200 (Word8.fromInt 255))
                            , String.join " " (List.map Int8.toString (List.sortBy (\x -> -x) i8))
                            , String.join " " (List.map Int8.toString (List.sortWith (\a b -> compare b a) i8))
                            , Debug.toString (compare ( Int8.fromInt -1, Word16.fromInt 5 ) ( Int8.fromInt -1, Word16.fromInt 7 ))
                            , Debug.toString (( Int8.fromInt -1, Word16.fromInt 5 ) < ( Int8.fromInt 1, Word16.fromInt 0 ))
                            , Debug.toString ([ Word8.fromInt 200 ] < [ Word8.fromInt 255 ])
                            , Debug.toString (compare [ Int32.fromInt -5, Int32.fromInt 1 ] [ Int32.fromInt -5 ])
                            , Debug.toString (List.member (Int16.fromInt -3) [ Int16.fromInt 1, Int16.fromInt -3 ])
                            , String.join " " (List.map (\( ( a, b ), v ) -> Int8.toString a ++ "," ++ Int8.toString b ++ ":" ++ v) (Dict.toList (Dict.fromList [ ( ( Int8.fromInt 1, Int8.fromInt 0 ), "b" ), ( ( Int8.fromInt -1, Int8.fromInt 2 ), "a" ) ])))
                            , String.join " " (List.map Float32.toString (Set.toList (Set.fromList [ Float32.fromFloat 0.5, -2, 3, Float32.fromFloat 0.5 ])))
                            , Debug.toString (Dict.get (Word16.fromInt 65535) (Dict.fromList [ ( Word16.fromInt -1, "max" ) ]))
                            , Debug.toString (Dict.member (Float32.fromFloat 0.1) (Dict.fromList [ ( Float32.fromFloat 0.1, 1 ) ]))
                            , Debug.toString (Float32.fromFloat 0.1 == Float32.fromFloat 0.1000000001)
                            , Word8.toString (List.foldl (+) 0 w8)
                            , Int8.toString (List.sum i8)
                            , Word16.toString (List.product [ 300, 300 ])
                            ]

                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
