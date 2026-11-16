module Hidden exposing (make, Pair(..), pairOf)

import Hidden.Core exposing (Money(..))


make : Int -> Money
make n =
    Money n


type Pair = Pair Money Money


pairOf : Int -> Pair
pairOf n =
    Pair (Money n) (Money (n + 1))
