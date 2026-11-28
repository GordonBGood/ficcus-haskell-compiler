module Purse exposing (Purse, make, value)


type Purse = Purse Int


make : Int -> Purse
make =
    Purse


value : Purse -> Int
value (Purse n) =
    n
