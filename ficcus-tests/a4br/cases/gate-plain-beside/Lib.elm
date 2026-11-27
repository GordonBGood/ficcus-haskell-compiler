module Lib exposing (sortM)


sortM : List (Maybe Int) -> List (Maybe Int)
sortM xs =
    List.sort xs
