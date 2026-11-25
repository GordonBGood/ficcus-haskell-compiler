module Main exposing (main)

import Purse exposing (Purse)
import Purse as P


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (( Purse.value (Purse.make 3), P.value (P.make 4) ))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
