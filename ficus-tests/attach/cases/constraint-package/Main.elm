module Main exposing (main)

import Algebra
import Algebra.Extra
import Finance.Money as Fm exposing (Money(..))



main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (( Money.toInt (Algebra.sum [ Money 1, Money 2, Fm.fromInt 4 ]), Algebra.double (Money 8), Algebra.Extra.sumTwice [ Money 1 ] ))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
