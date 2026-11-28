module Main exposing (main)

import Int8 exposing (Int8)
import Int16 exposing (Int16)
import Word8 exposing (Word8)
import Word64 exposing (Word64)
import Float32 exposing (Float32)


f : Word8 -> String
f x =
    case x of
        0 ->
            "zero"

        _ ->
            "other"


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }

