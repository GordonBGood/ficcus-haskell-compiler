module Main exposing (main)

import Dict
import Set
import Float32 exposing (Float32)


vals : List Float32
vals =
    List.map Float32.fromFloat [ 0.0, 1.0, -1.0, 0.10000000149011612, 0.20000000298023224, 0.30000001192092896, 3.1415927410125732, 16777216.0, 16777216.0, 10000000000.0, 1.000000013351432e-10, 3.4028234663852886e38, 1.1754943508222875e-38, 1.401298464324817e-45, 0.5, 2.5, -2.5, 100.0, 1.0000000200408773e21, 1.0000000116860974e-07, 123456.7890625, (1 / 0), (-1 / 0), (0 / 0) ]

pairs : List ( Float32, Float32 )
pairs =
    List.concatMap (\a -> List.map (\b -> ( a, b )) vals) vals

row2 : String -> (Float32 -> Float32 -> String) -> String
row2 name f =
    name ++ " " ++ String.join " " (List.map (\( a, b ) -> f a b) pairs)

row1 : String -> (Float32 -> String) -> String
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
                            [ row2 "add" (\a b -> Float32.toString (a + b))
                            , row2 "sub" (\a b -> Float32.toString (a - b))
                            , row2 "mul" (\a b -> Float32.toString (a * b))
                            , row2 "div" (\a b -> Float32.toString (a / b))
                            , row2 "lt" (\a b -> Debug.toString (a < b))
                            , row2 "le" (\a b -> Debug.toString (a <= b))
                            , row2 "gt" (\a b -> Debug.toString (a > b))
                            , row2 "ge" (\a b -> Debug.toString (a >= b))
                            , row2 "eq" (\a b -> Debug.toString (a == b))
                            , row2 "compare" (\a b -> Debug.toString (compare a b))
                            , row1 "neg" (\a -> Float32.toString (-a))
                            , row1 "abs" (\a -> Float32.toString (abs a))
                            , row1 "toFloat" (\a -> String.fromFloat (Float32.toFloat a))
                            , row1 "debug" (\a -> Debug.toString a)
                            , row1 "round" (\a -> Float32.toString (Float32.fromFloat (Float32.toFloat a)))
                            , "pow " ++ String.join " " (List.map (\( a, b ) -> Float32.toString (a ^ b)) [ ( Float32.fromFloat 0.5, Float32.fromFloat 0.5 ), ( Float32.fromFloat 0.5, Float32.fromFloat 1.0 ), ( Float32.fromFloat 0.5, Float32.fromFloat 2.0 ), ( Float32.fromFloat 0.5, Float32.fromFloat 3.0 ), ( Float32.fromFloat 0.5, Float32.fromFloat 10.0 ), ( Float32.fromFloat 0.5, Float32.fromFloat -2.0 ), ( Float32.fromFloat 1.0, Float32.fromFloat 0.5 ), ( Float32.fromFloat 1.0, Float32.fromFloat 1.0 ), ( Float32.fromFloat 1.0, Float32.fromFloat 2.0 ), ( Float32.fromFloat 1.0, Float32.fromFloat 3.0 ), ( Float32.fromFloat 1.0, Float32.fromFloat 10.0 ), ( Float32.fromFloat 1.0, Float32.fromFloat -2.0 ), ( Float32.fromFloat 2.0, Float32.fromFloat 0.5 ), ( Float32.fromFloat 2.0, Float32.fromFloat 1.0 ), ( Float32.fromFloat 2.0, Float32.fromFloat 2.0 ), ( Float32.fromFloat 2.0, Float32.fromFloat 3.0 ), ( Float32.fromFloat 2.0, Float32.fromFloat 10.0 ), ( Float32.fromFloat 2.0, Float32.fromFloat -2.0 ), ( Float32.fromFloat 3.0, Float32.fromFloat 0.5 ), ( Float32.fromFloat 3.0, Float32.fromFloat 1.0 ), ( Float32.fromFloat 3.0, Float32.fromFloat 2.0 ), ( Float32.fromFloat 3.0, Float32.fromFloat 3.0 ), ( Float32.fromFloat 3.0, Float32.fromFloat 10.0 ), ( Float32.fromFloat 3.0, Float32.fromFloat -2.0 ), ( Float32.fromFloat 10.0, Float32.fromFloat 0.5 ), ( Float32.fromFloat 10.0, Float32.fromFloat 1.0 ), ( Float32.fromFloat 10.0, Float32.fromFloat 2.0 ), ( Float32.fromFloat 10.0, Float32.fromFloat 3.0 ), ( Float32.fromFloat 10.0, Float32.fromFloat 10.0 ), ( Float32.fromFloat 10.0, Float32.fromFloat -2.0 ), ( Float32.fromFloat -2.0, Float32.fromFloat 0.5 ), ( Float32.fromFloat -2.0, Float32.fromFloat 1.0 ), ( Float32.fromFloat -2.0, Float32.fromFloat 2.0 ), ( Float32.fromFloat -2.0, Float32.fromFloat 3.0 ), ( Float32.fromFloat -2.0, Float32.fromFloat 10.0 ), ( Float32.fromFloat -2.0, Float32.fromFloat -2.0 ) ])
                            ]

                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
