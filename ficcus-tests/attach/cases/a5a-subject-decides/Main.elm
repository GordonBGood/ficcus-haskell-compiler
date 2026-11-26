module Main exposing (main)



type T = T Int
    where
        f : T -> Int
        f (T n) = n


type W = W T
    where
        f : W -> T
        f (W t) = t


get : a -> b
    where
        a has f : a -> b
get x =
    f x

get1 t =
    get t

get2 w =
    get (get w)


out =
    ( get2 (W (T 41)) + 1, get1 (W (T 5)), get1 (T 3) )



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
