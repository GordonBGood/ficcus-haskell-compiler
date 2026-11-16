module Main exposing (main)



total : Money
total =
    Money.sumAll [ Money 5, Money 6 ]


type Money = Money Int
    where
        zero : Money
        zero = Money 0

        add : Money -> Money -> Money
        add (Money a) (Money b) = Money (a + b)

        toInt : Money -> Int
        toInt (Money a) = a

        sumAll : List t -> t
            where
                t has zero as z : t
                t has add as plus : t -> t -> t
        sumAll ts =
            List.foldl plus z ts


type V2 = V2 Float Float
    where
        zero : V2
        zero = V2 0 0

        add : V2 -> V2 -> V2
        add (V2 a b) (V2 c d) = V2 (a + c) (b + d)


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (( Money.sumAll [ Money 7, Money 8 ], Money.sumAll [ V2 1 1, V2 2 2 ], total ))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
