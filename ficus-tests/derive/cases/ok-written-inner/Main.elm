module Main exposing (main)



type Money
    = Money Int
    where
        compare : Money -> Money -> Order
        compare (Money a) (Money b) = Basics.compare a b

type Wallet = Wallet (List Money) where derive compare


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
