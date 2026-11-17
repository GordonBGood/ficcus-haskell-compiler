module VecUse exposing (sumTo)

import Vector


sumTo : Int -> Int
sumTo n =
    Vector.initialize n (\i -> i + 1)
        |> Vector.toList
        |> List.sum
