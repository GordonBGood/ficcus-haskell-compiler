module Main exposing (main)

import Algebra exposing (sum)
import Algebra as A
import Types exposing (Money(..), V2(..))



main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (( Algebra.sum [ Money 1, Money 2 ], A.double (V2 1 2), sum [ Types.Money 4 ] ))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
