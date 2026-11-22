module Main exposing (main)


{-| `+` needs the whole `number` bundle; this type has `add` and `compare` only. -}
type Money
    = Money Int
    where
        add : Money -> Money -> Money
        add (Money a) (Money b) =
            Money (a + b)

        compare : Money -> Money -> Order
        compare (Money a) (Money b) =
            Basics.compare a b


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (Money 1 + Money 2 == Money 3)
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
