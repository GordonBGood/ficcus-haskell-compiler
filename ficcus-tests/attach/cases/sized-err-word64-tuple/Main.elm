module Main exposing (main)

import Int8 exposing (Int8)
import Int16 exposing (Int16)
import Word8 exposing (Word8)
import Word64 exposing (Word64)
import Float32 exposing (Float32)


f : Word64 -> Word64 -> Bool
f a b =
    ( a, 1 ) < ( b, 1 )


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), if f 1 2 then Cmd.none else Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }

