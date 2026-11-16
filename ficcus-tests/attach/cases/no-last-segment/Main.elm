module Main exposing (main)

import Finance.Money exposing (Money(..))


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (Money.toInt (Finance.Money.add Money.zero (Money 20)))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
