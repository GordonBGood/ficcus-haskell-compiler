module Main exposing (main)

import Dict
import Set
import Word8 exposing (Word8)


vals : List Word8
vals =
    List.map Word8.fromInt [ 0, 1, 2, 3, 7, 8, 15, 16, 100, 127, 128, 254, 255 ]

pairs : List ( Word8, Word8 )
pairs =
    List.concatMap (\a -> List.map (\b -> ( a, b )) vals) vals

row2 : String -> (Word8 -> Word8 -> String) -> String
row2 name f =
    name ++ " " ++ String.join " " (List.map (\( a, b ) -> f a b) pairs)

row1 : String -> (Word8 -> String) -> String
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
                            [ row2 "add" (\a b -> Word8.toString (a + b))
                            , row2 "sub" (\a b -> Word8.toString (a - b))
                            , row2 "mul" (\a b -> Word8.toString (a * b))
                            , row2 "pow" (\a b -> Word8.toString (a ^ b))
                            , row2 "idiv" (\a b -> Word8.toString (a // b))
                            , row2 "modBy" (\a b -> Word8.toString (modBy a b))
                            , row2 "remainderBy" (\a b -> Word8.toString (remainderBy a b))
                            , row2 "and" (\a b -> Word8.toString (Word8.and a b))
                            , row2 "or" (\a b -> Word8.toString (Word8.or a b))
                            , row2 "xor" (\a b -> Word8.toString (Word8.xor a b))
                            , row2 "lt" (\a b -> Debug.toString (a < b))
                            , row2 "le" (\a b -> Debug.toString (a <= b))
                            , row2 "gt" (\a b -> Debug.toString (a > b))
                            , row2 "ge" (\a b -> Debug.toString (a >= b))
                            , row2 "eq" (\a b -> Debug.toString (a == b))
                            , row2 "ne" (\a b -> Debug.toString (a /= b))
                            , row2 "compare" (\a b -> Debug.toString (compare a b))
                            , row2 "max" (\a b -> Word8.toString (max a b))
                            , row2 "min" (\a b -> Word8.toString (min a b))
                            , row1 "neg" (\a -> Word8.toString (-a))
                            , row1 "negate" (\a -> Word8.toString (negate a))
                            , row1 "abs" (\a -> Word8.toString (abs a))
                            , row1 "complement" (\a -> Word8.toString (Word8.complement a))
                            , row1 "popCount" (\a -> String.fromInt (Word8.popCount a))
                            , row1 "toInt" (\a -> String.fromInt (Word8.toInt a))
                            , row1 "toString" (\a -> Word8.toString a)
                            , row1 "roundtrip" (\a -> Word8.toString (Word8.fromInt (Word8.toInt a)))
                            , row1 "shl0" (\a -> Word8.toString (Word8.shiftLeftBy (0) a))
                            , row1 "shr0" (\a -> Word8.toString (Word8.shiftRightBy (0) a))
                            , row1 "shl1" (\a -> Word8.toString (Word8.shiftLeftBy (1) a))
                            , row1 "shr1" (\a -> Word8.toString (Word8.shiftRightBy (1) a))
                            , row1 "shl7" (\a -> Word8.toString (Word8.shiftLeftBy (7) a))
                            , row1 "shr7" (\a -> Word8.toString (Word8.shiftRightBy (7) a))
                            , row1 "shl8" (\a -> Word8.toString (Word8.shiftLeftBy (8) a))
                            , row1 "shr8" (\a -> Word8.toString (Word8.shiftRightBy (8) a))
                            , row1 "shl15" (\a -> Word8.toString (Word8.shiftLeftBy (15) a))
                            , row1 "shr15" (\a -> Word8.toString (Word8.shiftRightBy (15) a))
                            , row1 "shl16" (\a -> Word8.toString (Word8.shiftLeftBy (16) a))
                            , row1 "shr16" (\a -> Word8.toString (Word8.shiftRightBy (16) a))
                            , row1 "shl31" (\a -> Word8.toString (Word8.shiftLeftBy (31) a))
                            , row1 "shr31" (\a -> Word8.toString (Word8.shiftRightBy (31) a))
                            , row1 "shl32" (\a -> Word8.toString (Word8.shiftLeftBy (32) a))
                            , row1 "shr32" (\a -> Word8.toString (Word8.shiftRightBy (32) a))
                            , row1 "shl63" (\a -> Word8.toString (Word8.shiftLeftBy (63) a))
                            , row1 "shr63" (\a -> Word8.toString (Word8.shiftRightBy (63) a))
                            , row1 "shl64" (\a -> Word8.toString (Word8.shiftLeftBy (64) a))
                            , row1 "shr64" (\a -> Word8.toString (Word8.shiftRightBy (64) a))
                            , row1 "shl-1" (\a -> Word8.toString (Word8.shiftLeftBy (-1) a))
                            , row1 "shr-1" (\a -> Word8.toString (Word8.shiftRightBy (-1) a))
                            , row1 "minmax" (\a -> Word8.toString Word8.minValue ++ "/" ++ Word8.toString Word8.maxValue)
                            ]

                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
