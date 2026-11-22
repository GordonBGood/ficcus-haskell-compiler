module Main exposing (main)

import Dict
import Set
import Int16 exposing (Int16)


vals : List Int16
vals =
    List.map Int16.fromInt [ -32768, -32767, -2, -1, 0, 1, 2, 3, 7, 8, 15, 16, 100, 127, 128, 255, 256, 32766, 32767 ]

pairs : List ( Int16, Int16 )
pairs =
    List.concatMap (\a -> List.map (\b -> ( a, b )) vals) vals

row2 : String -> (Int16 -> Int16 -> String) -> String
row2 name f =
    name ++ " " ++ String.join " " (List.map (\( a, b ) -> f a b) pairs)

row1 : String -> (Int16 -> String) -> String
row1 name f =
    name ++ " " ++ String.join " " (List.map f vals)

logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        logAll
                            [ row2 "add" (\a b -> Int16.toString (a + b))
                            , row2 "sub" (\a b -> Int16.toString (a - b))
                            , row2 "mul" (\a b -> Int16.toString (a * b))
                            , row2 "pow" (\a b -> Int16.toString (a ^ b))
                            , row2 "idiv" (\a b -> Int16.toString (a // b))
                            , row2 "modBy" (\a b -> Int16.toString (modBy a b))
                            , row2 "remainderBy" (\a b -> Int16.toString (remainderBy a b))
                            , row2 "and" (\a b -> Int16.toString (Int16.and a b))
                            , row2 "or" (\a b -> Int16.toString (Int16.or a b))
                            , row2 "xor" (\a b -> Int16.toString (Int16.xor a b))
                            , row2 "lt" (\a b -> Debug.toString (a < b))
                            , row2 "le" (\a b -> Debug.toString (a <= b))
                            , row2 "gt" (\a b -> Debug.toString (a > b))
                            , row2 "ge" (\a b -> Debug.toString (a >= b))
                            , row2 "eq" (\a b -> Debug.toString (a == b))
                            , row2 "ne" (\a b -> Debug.toString (a /= b))
                            , row2 "compare" (\a b -> Debug.toString (compare a b))
                            , row2 "max" (\a b -> Int16.toString (max a b))
                            , row2 "min" (\a b -> Int16.toString (min a b))
                            , row1 "neg" (\a -> Int16.toString (-a))
                            , row1 "negate" (\a -> Int16.toString (negate a))
                            , row1 "abs" (\a -> Int16.toString (abs a))
                            , row1 "complement" (\a -> Int16.toString (Int16.complement a))
                            , row1 "popCount" (\a -> String.fromInt (Int16.popCount a))
                            , row1 "toInt" (\a -> String.fromInt (Int16.toInt a))
                            , row1 "toString" (\a -> Int16.toString a)
                            , row1 "roundtrip" (\a -> Int16.toString (Int16.fromInt (Int16.toInt a)))
                            , row1 "shl0" (\a -> Int16.toString (Int16.shiftLeftBy (0) a))
                            , row1 "shr0" (\a -> Int16.toString (Int16.shiftRightBy (0) a))
                            , row1 "shl1" (\a -> Int16.toString (Int16.shiftLeftBy (1) a))
                            , row1 "shr1" (\a -> Int16.toString (Int16.shiftRightBy (1) a))
                            , row1 "shl7" (\a -> Int16.toString (Int16.shiftLeftBy (7) a))
                            , row1 "shr7" (\a -> Int16.toString (Int16.shiftRightBy (7) a))
                            , row1 "shl8" (\a -> Int16.toString (Int16.shiftLeftBy (8) a))
                            , row1 "shr8" (\a -> Int16.toString (Int16.shiftRightBy (8) a))
                            , row1 "shl15" (\a -> Int16.toString (Int16.shiftLeftBy (15) a))
                            , row1 "shr15" (\a -> Int16.toString (Int16.shiftRightBy (15) a))
                            , row1 "shl16" (\a -> Int16.toString (Int16.shiftLeftBy (16) a))
                            , row1 "shr16" (\a -> Int16.toString (Int16.shiftRightBy (16) a))
                            , row1 "shl31" (\a -> Int16.toString (Int16.shiftLeftBy (31) a))
                            , row1 "shr31" (\a -> Int16.toString (Int16.shiftRightBy (31) a))
                            , row1 "shl32" (\a -> Int16.toString (Int16.shiftLeftBy (32) a))
                            , row1 "shr32" (\a -> Int16.toString (Int16.shiftRightBy (32) a))
                            , row1 "shl63" (\a -> Int16.toString (Int16.shiftLeftBy (63) a))
                            , row1 "shr63" (\a -> Int16.toString (Int16.shiftRightBy (63) a))
                            , row1 "shl64" (\a -> Int16.toString (Int16.shiftLeftBy (64) a))
                            , row1 "shr64" (\a -> Int16.toString (Int16.shiftRightBy (64) a))
                            , row1 "shl-1" (\a -> Int16.toString (Int16.shiftLeftBy (-1) a))
                            , row1 "shr-1" (\a -> Int16.toString (Int16.shiftRightBy (-1) a))
                            , row1 "minmax" (\a -> Int16.toString Int16.minValue ++ "/" ++ Int16.toString Int16.maxValue)
                            ]

                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
