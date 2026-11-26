module Main exposing (main)

import Lib exposing (Money(..), Vec(..))




out =
    ( add (Money 1) zero, add zero (Vec 1 2) )



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
