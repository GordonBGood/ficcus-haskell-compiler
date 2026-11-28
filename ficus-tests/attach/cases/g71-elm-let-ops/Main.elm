module Main exposing (main)



out =
    let
        hd y =
            y / 4

        hi y =
            y // 4

        hm y =
            modBy 4 y

        hp y =
            y + y

        hc a b =
            compare a b

        hl a b =
            a < b
    in
    ( ( hd 3, hd 2.5, hi 9 ), ( hi 10, hm 9, hm 10 ), ( ( hp 1, hp 1.5 ), ( hc 1 2, hc "b" "a" ), ( hl 1 2, hl "b" "a" ) ) )



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
