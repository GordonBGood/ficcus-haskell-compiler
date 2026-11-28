module Main exposing (main)

import Algebra
import Wrap


unbox : Wrap.Box (List a) -> a
    where
        a has zero : a
unbox (Wrap.Box xs) =
    case xs of
        x :: _ -> x
        [] -> zero



main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (( Algebra.sum [ Wrap.mk 1, Wrap.mk 2 ], Algebra.double (Wrap.mk 21), unbox (Wrap.boxed 5) ))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
