module Main exposing (main)


type T = T Int
    where
        f : T -> Int
        f (T n) = n

        g : Int -> Int
        g f = f + 1


main : Program () () ()
main =
    Platform.worker { init = \_ -> ( (), Cmd.none ), update = \_ m -> ( m, Cmd.none ), subscriptions = \_ -> Sub.none }
