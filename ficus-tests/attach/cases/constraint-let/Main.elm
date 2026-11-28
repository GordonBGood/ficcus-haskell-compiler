module Main exposing (main)


f : Int -> Int
f n =
    let
        g : a -> a
            where
                a has add : a -> a -> a
        g x =
            add x x
    in
    n


main : Program () () ()
main =
    Platform.worker { init = \_ -> ( (), Cmd.none ), update = \_ m -> ( m, Cmd.none ), subscriptions = \_ -> Sub.none }
