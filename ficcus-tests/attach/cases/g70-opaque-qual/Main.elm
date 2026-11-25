module Main exposing (main)

import Finance


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (( Finance.Money.toInt (Finance.Money.add (Finance.fromInt 1) (Finance.fromInt 2)), Finance.Money.compare (Finance.fromInt 1) (Finance.fromInt 2) ))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
