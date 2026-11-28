module Main exposing (main)

-- plain Elm (no member): List.sort with a NaN beside a String, through the kernel sort


nan : Float
nan =
    0 / 0


lines : List String
lines =
    [ Debug.toString (List.sort [ ( "b", 2 ), ( "a", nan ), ( "a", 1 ) ] |> List.map Tuple.second)
    , Debug.toString (List.sortWith compare [ ( "b", 2 ), ( "a", nan ), ( "a", 1 ) ] |> List.map Tuple.second)
    , Debug.toString (List.sort [ ( "b", 2 ), ( "a", 1 ), ( "a", nan ), ( "a", 0 ), ( "c", nan ), ( "a", -1 ) ] |> List.map Tuple.second)
    , Debug.toString (List.sortWith compare [ ( "b", 2 ), ( "a", 1 ), ( "a", nan ), ( "a", 0 ), ( "c", nan ), ( "a", -1 ) ] |> List.map Tuple.second)
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
