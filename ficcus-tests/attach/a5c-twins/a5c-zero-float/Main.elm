module Main exposing (main)






out =
    ( List.foldl (+) 0 [ 1.5, 2 ], List.foldl (+) 0 [ 0.25 ] )



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
