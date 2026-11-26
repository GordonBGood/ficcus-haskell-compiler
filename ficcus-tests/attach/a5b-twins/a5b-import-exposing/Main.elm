module Main exposing (main)

import Lib exposing (Money(..), Vec(..))




out =
    ( Money.add (Money 1) Money.zero, Vec.add Vec.zero (Vec 1 2) )



main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" out
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
