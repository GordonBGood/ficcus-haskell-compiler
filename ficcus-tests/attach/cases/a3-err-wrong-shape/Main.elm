module Main exposing (main)


type Money
    = Money Int
    where
        add : Money -> Int -> Money
        add (Money a) b =
            Money (a + b)


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (Money 1)
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
