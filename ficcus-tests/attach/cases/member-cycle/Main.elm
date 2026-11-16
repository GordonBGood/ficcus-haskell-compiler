module Main exposing (main)


type T = T Int
    where
        a : Int
        a = b + 1

        b : Int
        b = a + 1


main : Program () () ()
main =
    Platform.worker { init = \_ -> ( (), Cmd.none ), update = \_ m -> ( m, Cmd.none ), subscriptions = \_ -> Sub.none }
