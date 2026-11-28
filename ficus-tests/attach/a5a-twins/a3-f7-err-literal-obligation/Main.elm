module Main exposing (main)


smallest : a -> a -> a
    where
        a has compare : a -> a -> Order
smallest x y =
    case compare x y of
        GT ->
            y

        _ ->
            x


three : Int
three =
    3


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> let _ = Debug.log "r" (smallest three 2) in ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
