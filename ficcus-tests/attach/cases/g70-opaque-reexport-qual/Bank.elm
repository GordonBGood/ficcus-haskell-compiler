module Bank exposing (Cash, deposit, combine)

import Finance exposing (Money)


type alias Cash =
    Money


deposit : Int -> Cash
deposit =
    Finance.fromInt


combine : Cash -> Cash -> Cash
combine a b =
    Money.add a b
