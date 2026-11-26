module Main exposing (main)



type Q = Q Int
    where
        pick : Q -> c -> c
        pick _ x = x

        idq : Q -> Q
        idq q = q


choose : a -> c -> c
    where
        a has pick : a -> c -> c
choose x y =
    pick x y


k t =
    ( choose t, Q.idq t )


out =
    ( Tuple.first (k (Q 1)) 1, Tuple.first (k (Q 1)) "s" )



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
