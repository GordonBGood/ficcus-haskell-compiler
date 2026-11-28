module Main exposing (main)


type T = T Int
    where
        f : T -> Int
        f (T n) = n


get : a -> b
    where
        a has f : a -> b
get x =
    f x


h t =
    let
        y =
            get t
    in
    ( y + 1, T.f t )


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (h (T 41))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
