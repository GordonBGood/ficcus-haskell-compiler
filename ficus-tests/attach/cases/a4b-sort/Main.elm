module Main exposing (main)

import Vector


type Color
    = Red
    | Green
    | Blue
    where
        derive compare


type Ci
    = Ci String
    where
        compare : Ci -> Ci -> Order
        compare (Ci a) (Ci b) =
            Basics.compare (String.toLower a) (String.toLower b)


color : Int -> Color
color i =
    case i of
        0 ->
            Red

        1 ->
            Green

        _ ->
            Blue


rank : Color -> Int
rank c =
    case c of
        Red ->
            0

        Green ->
            1

        Blue ->
            2


seq : List Int
seq =
    List.map (\i -> modBy 3 (i * 7 + i // 5)) (List.range 0 99)


lines : List String
lines =
    [ Debug.toString (List.map rank (List.sort (List.map color seq)))
    , Debug.toString (List.map Tuple.second (List.sortBy Tuple.first (List.indexedMap (\i k -> ( color k, i )) seq)))
    , Debug.toString (List.map Tuple.second (List.sortWith (\( a, _ ) ( b, _ ) -> Color.compare a b) (List.indexedMap (\i k -> ( color k, i )) seq)))
    , Debug.toString (List.map (\( c, i ) -> rank c * 1000 + i) (List.sort (List.indexedMap (\i k -> ( color k, modBy 4 i )) seq)))
    , Debug.toString (Vector.toList (Vector.map rank (Vector.sort (Vector.fromList (List.map color seq)))))
    , Debug.toString (List.map (\( c, Ci s ) -> String.fromInt (rank c) ++ s) (List.sort [ ( Blue, Ci "b" ), ( Red, Ci "B" ), ( Red, Ci "a" ), ( Blue, Ci "A" ) ]))
    , Debug.toString (List.map (Maybe.map rank) (List.sort [ Just Blue, Nothing, Just Red, Nothing ]))
    ]


logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> let _ = logAll lines in ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
