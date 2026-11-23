module Vector exposing (Vector, fromList, length, toList)


type Vector
    = Vector (List Int)


fromList : List Int -> Vector
fromList xs =
    Vector xs


length : Vector -> Int
length (Vector xs) =
    List.length xs * 100


toList : Vector -> List Int
toList (Vector xs) =
    List.reverse xs
