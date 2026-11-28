module Main exposing (main)

import Finance as F exposing (Money)


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (( Money.toInt (Money.add (F.fromInt 1) (F.fromInt 2)), Money.compare (F.fromInt 1) (F.fromInt 2) ))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
