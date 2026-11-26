module Main exposing (main)

import Float32 exposing (Float32)

scale : number -> number
    where
        number has fromFloat : Float -> number
scale x =
    x * 0.5

f3 : Float32
f3 =
    Float32.fromFloat 3

t3 : Float
t3 =
    3


out =
    ( Float32.toString (scale f3), scale t3 )



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
