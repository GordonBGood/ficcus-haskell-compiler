module Main exposing (main)



lines : List String
lines =
    [ Debug.toString ( ( 1, [ ( 3, "a" ) ] ) == ( 1, [ ( 4, "a" ) ] ), ( 1, [ ( 3, "a" ) ] ) == ( 1, [ ( 3, "a" ) ] ) ) ]


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
