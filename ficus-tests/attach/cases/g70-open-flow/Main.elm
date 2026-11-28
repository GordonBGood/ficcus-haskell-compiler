module Main exposing (main)

import Algebra
import Bank


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (Bank.combine (Algebra.sum [ Bank.deposit 1, Bank.deposit 2 ]) (Bank.deposit 10))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
