module Main exposing (main)



appz : a -> a -> a
    where
        a has append : a -> a -> a
appz x y =
    append x y


app2 x y =
    Debug.toString (appz x y)


lenOf x y =
    String.length (app2 x y)


out =
    ( app2 "a" "b", app2 [ 1 ] [ 2 ], lenOf "ab" "cd" )



main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" out
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
