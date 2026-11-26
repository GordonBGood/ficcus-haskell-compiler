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

pair w =
    let
        y =
            get w
    in
    ( y, y )


out =
    ( pair (T 1), pair (W (T 2)) )



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
