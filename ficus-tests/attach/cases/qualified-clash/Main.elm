module Main exposing (main)

import Money
import Types exposing (Money(..))




main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" ([ Money.add 1 2, Money.double 4, Money.toInt (Money.only 7), Money.toInt (Types.Money.add (Money 1) (Money 2)) ])
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
