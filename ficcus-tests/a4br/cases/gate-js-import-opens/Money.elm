module Money exposing (Money(..))


type Money
    = Money Int
    where
        toInt : Money -> Int
        toInt (Money n) =
            n
