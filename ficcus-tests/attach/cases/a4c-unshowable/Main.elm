module Main exposing (main)

import Vector exposing (Vector)
import Int8 exposing (Int8)
import Int16 exposing (Int16)
import Int32 exposing (Int32)
import Word8 exposing (Word8)
import Word16 exposing (Word16)
import Word32 exposing (Word32)
import Word64 exposing (Word64)
import Float32 exposing (Float32)


type Holder
    = H (Vector Int) (Vector (Maybe String))
    | S Int8 Int16 Int32
    | U Word8 Word16 Word32 Word64
    | F Float32
    | Nested (List Holder) (Vector Holder)
    where
        derive toString


showIt : a -> String
    where
        a has toString : a -> String
showIt x =
    toString x


lines : List String
lines =
    [ Holder.toString (H (Vector.fromList [ 1, -2 ]) (Vector.fromList [ Just "a b", Nothing ]))
    , Holder.toString (H (Vector.fromList []) (Vector.fromList []))
    , Holder.toString (S (Int8.fromInt -128) (Int16.fromInt 32767) (Int32.fromInt -5))
    , Holder.toString (U (Word8.fromInt 255) (Word16.fromInt -1) (Word32.fromInt 7) (Word64.shiftLeftBy 63 (Word64.fromInt 1)))
    , Holder.toString (F (Float32.fromFloat 0.1))
    , Holder.toString (F (Float32.fromFloat -1.5))
    , Holder.toString (Nested [ F (Float32.fromFloat 2) ] (Vector.fromList [ S (Int8.fromInt 1) (Int16.fromInt 2) (Int32.fromInt 3) ]))
    , showIt (Vector.fromList [ Word64.fromInt -1 ])
    , showIt ( Int8.fromInt -1, Float32.fromFloat 3 )
    ]


logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> let _ = logAll lines in ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
