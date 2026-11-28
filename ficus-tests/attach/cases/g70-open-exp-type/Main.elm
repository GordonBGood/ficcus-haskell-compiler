module Main exposing (main)

import Finance exposing (Money)


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (( Money.toInt (Money.add (Finance.fromInt 1) (Finance.fromInt 2)), Money.compare (Finance.fromInt 1) (Finance.fromInt 2) ))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
