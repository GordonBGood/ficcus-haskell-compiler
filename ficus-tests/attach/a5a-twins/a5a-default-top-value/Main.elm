module Main exposing (main)






out =
    ( 1 + 2, 3 / 2, ( 7 / 2, 7 // 2, modBy 3 7 ) )



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
