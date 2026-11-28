module Main exposing (main)

-- twin: the order is by String.length; sortWith / foldl reproduce Elm's sort (stable), maximum, minimum, max, min on that order


cmpL : List String -> List String -> Order
cmpL a b =
    compare (List.map String.length a) (List.map String.length b)


maxBy : (a -> a -> Order) -> a -> a -> a
maxBy c x y =
    if c x y == GT then x else y


minBy : (a -> a -> Order) -> a -> a -> a
minBy c x y =
    if c x y == LT then x else y


fold : (a -> a -> a) -> List a -> Maybe a
fold f xs =
    case xs of
        x :: rest ->
            Just (List.foldl f x rest)

        [] ->
            Nothing


cmpT : ( String, Int ) -> ( String, Int ) -> Order
cmpT ( a, i ) ( b, j ) =
    compare ( String.length a, i ) ( String.length b, j )


lines : List String
lines =
    [ List.sortWith cmpL [ [ "bb" ], [ "aa" ], [ "c" ], [ "dd" ] ] |> List.map (String.join ",") |> String.join ";"
    , List.sortWith (\( a, _ ) ( b, _ ) -> cmpL [ a ] [ b ]) [ ( "bb", 1 ), ( "aa", 2 ), ( "c", 3 ) ] |> List.map Tuple.first |> String.join ";"
    , fold (maxBy cmpL) [ [ "aa" ], [ "bb" ], [ "c" ] ] |> Maybe.map (String.join ",") |> Maybe.withDefault "-"
    , fold (minBy cmpL) [ [ "aa" ], [ "bb" ], [ "c" ] ] |> Maybe.map (String.join ",") |> Maybe.withDefault "-"
    , Tuple.first (maxBy cmpT ( "xx", 0 ) ( "yy", 0 ))
    , Tuple.first (minBy cmpT ( "xx", 0 ) ( "yy", 0 ))
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
