module Main exposing (main)


type Meters
    = Meters Float


f : Meters
f =
    0.5


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
