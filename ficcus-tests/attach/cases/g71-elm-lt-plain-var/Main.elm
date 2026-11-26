module Main exposing (main)



smaller : a -> a -> a
smaller a b =
    if a < b then
        a

    else
        b


out =
    smaller 3 2



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
