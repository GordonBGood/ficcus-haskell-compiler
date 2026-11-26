module Main exposing (main)

import Float32 exposing (Float32)




out =
    Float32.toString (Float32.fromFloat 1.5 + Float32.fromFloat 2)



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
