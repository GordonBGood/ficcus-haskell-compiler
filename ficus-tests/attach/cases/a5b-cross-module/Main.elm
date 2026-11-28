module Main exposing (main)

import Lib exposing (Money(..), Vec(..), total)




out =
    ( total [ Money 1, Money 2 ], total [ Vec 1 2, Vec 3 4 ] )



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
