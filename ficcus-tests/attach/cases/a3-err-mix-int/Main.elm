module Main exposing (main)


type Money
    = Money Int
    where
        add : Money -> Money -> Money
        add (Money a) (Money b) =
            Money (a + b)

        sub : Money -> Money -> Money
        sub (Money a) (Money b) =
            Money (a - b)

        mul : Money -> Money -> Money
        mul (Money a) (Money b) =
            Money (a * b)

        pow : Money -> Money -> Money
        pow (Money a) (Money b) =
            Money (a ^ b)

        neg : Money -> Money
        neg (Money a) =
            Money (negate a)

        abs : Money -> Money
        abs (Money a) =
            Money (Basics.abs a)

        fromInt : Int -> Money
        fromInt n =
            Money n

        compare : Money -> Money -> Order
        compare (Money a) (Money b) =
            Basics.compare a b


seven : Int
seven =
    7


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (Money 1 + seven)
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
