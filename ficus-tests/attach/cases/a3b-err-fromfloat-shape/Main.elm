module Main exposing (main)


type Meters
    = Meters Float
    where
        fromFloat : Int -> Meters
        fromFloat x =
            Meters (toFloat x)


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
