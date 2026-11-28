module Main exposing (main)

import Float32 exposing (Float32)

scale x =
    x * 0.5


out =
    ( Float32.toString (scale (Float32.fromFloat 3)), scale 3 )



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
