module Main exposing (main)

import Vector exposing (Vector)


v : Vector Int
v =
    Vector.push 4 (Vector.fromList [ 1, 2, 3 ])


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "core Vector" ( Vector.length v, Vector.toList (Vector.set 1 20 v) )
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
