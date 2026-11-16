module VecPkg exposing (doubled)

import Vector exposing (Vector)


doubled : Vector Int -> Vector Int
doubled v =
    Vector.append v v
