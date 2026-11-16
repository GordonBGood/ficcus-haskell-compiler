module Main exposing (main)


type Money = Money Int
    where
        zero : Money
        zero = Money 0

        add : Money -> Money -> Money
        add (Money a) (Money b) = Money (a + b)

        double : Money -> Money
        double m = add m m

        sum : List Money -> Money
        sum ms = List.foldl add zero ms

        toInt : Money -> Int
        toInt (Money a) = a

        count : Int -> Int
        count n = if n <= 0 then 0 else 1 + count (n - 1)


type Nat = Z | S Nat
    where
        isEven : Nat -> Bool
        isEven n =
            case n of
                Z -> True
                S m -> isOdd m

        isOdd : Nat -> Bool
        isOdd n =
            case n of
                Z -> False
                S m -> isEven m


add : Int -> Int -> Int
add a b = a * 100 + b


zero : String
zero = "top"


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" ( ( Money.toInt (Money.sum [ Money 1, Money 2, Money.double (Money 10) ]), add 1 2, zero ), ( Money.count 3, Nat.isEven (S (S Z)), Nat.isOdd (S (S Z)) ) )
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
