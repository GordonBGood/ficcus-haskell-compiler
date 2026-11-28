module Main exposing (main)

import Float32 exposing (Float32)
import Word8 exposing (Word8)




out =
    ( Word8.toInt (List.foldl (+) (Word8.fromInt 0) [ Word8.fromInt 200, Word8.fromInt 100 ]), Float32.toString (List.foldl (+) (Float32.fromInt 0) [ Float32.fromFloat 0.5, Float32.fromFloat 0.25 ]) )



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
