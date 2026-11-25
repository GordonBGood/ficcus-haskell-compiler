module Main exposing (main)

import Finance exposing (..)


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (( Money.toInt (Money.add (fromInt 1) (fromInt 2)), Money.compare (fromInt 1) (fromInt 2) ))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
