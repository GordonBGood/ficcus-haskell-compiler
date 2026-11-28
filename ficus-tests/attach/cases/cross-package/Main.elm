module Main exposing (main)

import Finance.Money as Fm
import Finance.Money exposing (Money(..))




main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" ([ Money.toInt (Money.add (Fm.fromInt 3) (Fm.Money.add (Money 4) Fm.Money.zero)), Money.toInt (Finance.Money.Money.add Money.zero (Money 20)) ])
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
