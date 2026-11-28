module Main exposing (main)

import Float32 exposing (Float32)


half =
    0.5


y : Float32
y =
    half


x =
    Float32.toFloat y


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> let _ = Debug.log "r" (Debug.toString x) in ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
