module Main exposing (main)

import Vector
import VecPkg


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "doubled" (VecPkg.doubled (Vector.fromList [ 1, 2 ]))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
