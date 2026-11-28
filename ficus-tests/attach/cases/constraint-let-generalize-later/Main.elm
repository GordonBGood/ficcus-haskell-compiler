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
    let
        y =
            choose t
    in
    ( y, Q.idq t )


u : Float
u =
    Tuple.first (k (Q 1)) 2.5


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (( Tuple.first (k (Q 1)) 1.5, Tuple.first (k (Q 1)) "s", u ))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
