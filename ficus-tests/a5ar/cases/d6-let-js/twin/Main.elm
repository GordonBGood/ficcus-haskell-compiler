module Main exposing (main)

f : Float -> Int -> ( Float, Int )
f x n =
    let
        g y =
            y / 2

        h y =
            y // 2
    in
    ( g x, h n )


out =
    f 3 7


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" out
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
