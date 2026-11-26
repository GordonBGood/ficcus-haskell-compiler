module Main exposing (main)



smaller a b =
    if a < b then
        a

    else
        b


order a b =
    compare a b


same a b =
    a == b


dbl x =
    x + x


out =
    ( ( smaller 3 2, smaller "b" "a", order 3 2 ), ( same 3 3, dbl 3, dbl 1.5 ) )



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
