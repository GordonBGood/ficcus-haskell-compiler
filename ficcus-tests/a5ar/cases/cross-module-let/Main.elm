module Main exposing (main)

import Helper exposing (Money(..), Vec(..), twice)


out =
    let
        g x =
            twice (twice x)
    in
    ( g (Money 1), g (Vec 1 2) )


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
