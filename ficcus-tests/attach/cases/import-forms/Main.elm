module Main exposing (main)

import Counter
import Counter as C
import Counter exposing (Counter)




main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" ([ Counter.value (Counter.inc Counter.start), C.Counter.value (C.Counter.inc (C.Counter.inc Counter.start)), Counter.value (Counter.Counter.inc (Counter.Counter.inc (Counter.Counter.inc Counter.start))), C.Counter.value (Counter.inc C.start) ])
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
