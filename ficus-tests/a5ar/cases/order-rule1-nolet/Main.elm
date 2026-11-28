module Main exposing (main)

type Q = Q Int
    where
        pick : Q -> c -> c
        pick _ x = x


choose : a -> c -> c
    where
        a has pick : a -> c -> c
choose x y =
    pick x y

both q =
    ( ( choose q 1, choose q "s" ), q == Q 1 )


out =
    both (Q 1)


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
