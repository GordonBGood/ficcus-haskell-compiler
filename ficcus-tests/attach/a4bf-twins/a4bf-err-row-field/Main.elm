module Main exposing (main)



lines : List String
lines =
    [ Debug.toString ( ( 1, 2 ) < ( 1, 3 ), compare ( 9, 2 ) ( 10, 1 ) )
    , Debug.toString ( ( 1, 2 ) == ( 1, 3 ), ( 1, 2 ) == ( 1, 2 ) )
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
