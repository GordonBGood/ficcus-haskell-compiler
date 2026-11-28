module Types exposing (Money(..))


type Money = Money Int
    where
        add : Money -> Money -> Money
        add (Money a) (Money b) = Money (a + b + 100)

        only : Int -> Money
        only n = Money n

        toInt : Money -> Int
        toInt (Money a) = a
