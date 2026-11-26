module Main exposing (main)

f x =
    let
        g y =
            Debug.toString ( y, 7 // 2, 7 / 2 )
    in
    g x


h y =
    y // 4


k =
    modBy 3 10


mm =
    let
        q z =
            z / 2
    in
    ( q 3, q 4.5 )


r a b =
    ( remainderBy a b, modBy a b )


v =
    7 / 2


out =
    ( ( f 1, h 9, k ), ( mm, r 3 -7, v ) )


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
