module Main exposing (main)


g : a -> a
    where
        a has zero : a
        a has one : a
g x y =
    x


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), Cmd.none ), update = \_ m -> ( m, Cmd.none ), subscriptions = \_ -> Sub.none }
