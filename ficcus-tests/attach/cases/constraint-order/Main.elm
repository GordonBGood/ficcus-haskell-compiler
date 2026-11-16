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


h1 w =
    let
        y =
            get (get w)
    in
    ( y + 1, W.f w )


h2 w =
    let
        y =
            w |> get |> get
    in
    ( y + 1, W.f w )


h3 w =
    let
        m =
            get w

        y =
            get m
    in
    ( y + 1, W.f w )


h4 w =
    ( get (get w) + 1, W.f w )


w0 : W
w0 =
    W (T 41)


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (( ( h1 w0, h2 w0 ), ( h3 w0, h4 w0 ) ))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
