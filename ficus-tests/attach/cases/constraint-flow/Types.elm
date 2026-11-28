module Types exposing (Money(..))


type Money = Money Int
    where
        zero : Money
        zero = Money 0

        add : Money -> Money -> Money
        add (Money a) (Money b) = Money (a + b)

        toInt : Money -> Int
        toInt (Money a) = a
