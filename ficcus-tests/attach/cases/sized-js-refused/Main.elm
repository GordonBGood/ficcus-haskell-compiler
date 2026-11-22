module Main exposing (main)

import Int8 exposing (Int8)


x : Int8
x =
    Int8.fromInt 5


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), if x == x then Cmd.none else Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
