module Main exposing (main)

import OwnVec
import Vector


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "own" (OwnVec.describe [ 1, 2, 3 ])

                    _ =
                        Debug.log "core" (Vector.length (Vector.fromList [ 1, 2, 3 ]))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
