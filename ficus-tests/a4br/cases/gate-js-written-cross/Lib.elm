module Lib exposing (Money(..), sortM)


type Money
    = Money Int
    where
        toInt : Money -> Int
        toInt (Money n) =
            n


sortM : List (Maybe Int) -> List (Maybe Int)
sortM xs =
    List.sort xs
