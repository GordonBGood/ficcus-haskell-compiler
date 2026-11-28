module Main exposing (main)

import Algebra
import Hidden


total : Hidden.Pair -> Hidden.Pair
total (Hidden.Pair a b) =
    Hidden.Pair (Algebra.double a) (Algebra.sum [ a, b ])


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" ( Algebra.sum [ Hidden.make 1, Hidden.make 2 ], total (Hidden.pairOf 3) )
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
