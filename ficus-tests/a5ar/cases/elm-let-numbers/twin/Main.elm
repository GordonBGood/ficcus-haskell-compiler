module Main exposing (main)

f x =
    let
        k =
            9

        g y =
            y / 2

        h y =
            y // 2
    in
    ( ( k + 1, toFloat k / 2 ), ( g x, h 9, modBy 4 9 ) )


out =
    f 3


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
