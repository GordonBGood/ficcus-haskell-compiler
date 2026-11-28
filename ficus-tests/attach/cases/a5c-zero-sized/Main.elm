module Main exposing (main)

import Float32 exposing (Float32)
import Word8 exposing (Word8)

sum : List a -> a
    where
        a has zero : a
        a has add : a -> a -> a
sum xs =
    List.foldl add zero xs


out =
    ( Word8.toInt (sum [ Word8.fromInt 200, Word8.fromInt 100 ]), Float32.toString (sum [ Float32.fromFloat 0.5, Float32.fromFloat 0.25 ]) )



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
