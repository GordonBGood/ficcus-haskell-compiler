module Main exposing (main)


f : Int -> a -> a
    where
        a has zero : a
f "x" y =
    y


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), Cmd.none ), update = \_ m -> ( m, Cmd.none ), subscriptions = \_ -> Sub.none }
