module Types exposing (Money(..), V2(..))


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
