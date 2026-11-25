module Main exposing (main)

import Bank
import Finance


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (( Finance.Money.toInt (Finance.Money.add (Bank.deposit 1) (Bank.deposit 2)), Finance.Money.compare (Bank.deposit 1) (Bank.deposit 2) ))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
