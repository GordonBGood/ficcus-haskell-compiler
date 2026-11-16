module Main exposing (main)



type Money = Money Int
    where
        zero : Money
        zero = Money 0

        add : Money -> Money -> Money
        add (Money a) (Money b) = Money (a + b)

        toInt : Money -> Int
        toInt (Money a) = a


type V2 = V2 Float Float
    where
        zero : V2
        zero = V2 0 0

        add : V2 -> V2 -> V2
        add (V2 a b) (V2 c d) = V2 (a + c) (b + d)


sum : List a -> a
    where
        a has zero : a
        a has add : a -> a -> a
sum xs =
    List.foldl add zero xs


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (( Money.toInt (sum [ Money 1, Money 2, Money 4 ]), sum [ V2 1 2, V2 3 4 ], sum [ Money 9 ] ))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
