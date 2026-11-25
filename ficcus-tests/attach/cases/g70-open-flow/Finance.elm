module Finance exposing (Money(..), fromInt)


type Money = Money Int
    where
        zero : Money
        zero = Money 0

        add : Money -> Money -> Money
        add (Money a) (Money b) = Money (a + b)

        compare : Money -> Money -> Order
        compare (Money a) (Money b) = Basics.compare a b

        toInt : Money -> Int
        toInt (Money a) = a


fromInt : Int -> Money
fromInt =
    Money


-- an ordinary function, not a member and not exported: it stays hidden
raw : Money -> Int
raw (Money a) =
    a
