module OwnVec exposing (describe)

import Vector


describe : List Int -> ( Int, List Int )
describe xs =
    let
        v =
            Vector.fromList xs
    in
    ( Vector.length v, Vector.toList v )
