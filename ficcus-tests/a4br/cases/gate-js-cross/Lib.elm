module Lib exposing (sortM)


type Color
    = Red
    where
        derive compare


sortM : List (Maybe Int) -> List (Maybe Int)
sortM xs =
    List.sort xs
