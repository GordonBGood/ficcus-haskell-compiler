module Main exposing (main)



type Money
    = Money Int
    where
        derive hash
        toInt : Money -> Int
        toInt (Money a) = a


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (Money.toInt (Money 7))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
