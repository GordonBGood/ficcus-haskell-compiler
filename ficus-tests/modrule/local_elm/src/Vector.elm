module Vector exposing (Vector, fromList, length, push, sum)


type Vector a
    = Vector (List a)


fromList : List a -> Vector a
fromList xs =
    Vector xs


length : Vector a -> Int
length (Vector xs) =
    List.length xs


push : a -> Vector a -> Vector a
push x (Vector xs) =
    Vector (xs ++ [ x ])


sum : Vector Int -> Int
sum (Vector xs) =
    List.sum xs
