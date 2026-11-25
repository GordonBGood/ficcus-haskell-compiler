module Main exposing (main)

import Finance as F


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (( F.Money.toInt (F.Money.add (F.fromInt 1) (F.fromInt 2)), F.Money.compare (F.fromInt 1) (F.fromInt 2) ))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
