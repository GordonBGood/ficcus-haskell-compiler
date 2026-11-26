module Main exposing (main)



type Money
    = Money Int
    where
        double : Money -> Money
        double (Money a) =
            Money (a * 2)

twice x =
    double (double x)


out =
    twice (Money 1)



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
