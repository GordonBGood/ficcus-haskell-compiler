module Main exposing (main)

import Counter exposing (..)




main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" ([ Counter.value (Counter.inc start), Counter.value (Counter.inc (Counter 5)) ])
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
