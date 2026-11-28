module Main exposing (main)

import Float32 exposing (Float32)

conv : a -> a
    where
        a has fromInt : Int -> a
conv _ =
    fromInt 3


show : Float32 -> String
show x =
    Float32.toString x


out =
    show (conv (Float32.fromFloat 1))



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
