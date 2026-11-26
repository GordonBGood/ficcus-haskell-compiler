module Main exposing (main)


type Meters
    = Meters Float
    where
        fromFloat : Float -> Meters
        fromFloat x =
            Meters x


type Feet
    = Feet Float


f : Feet
f =
    0.5


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
