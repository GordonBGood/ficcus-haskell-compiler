module Main exposing (main)



double : a -> a
    where
        a has add : a -> a -> a
        a has add as plus : a -> a -> a
double x =
    add x x


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (1)
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
