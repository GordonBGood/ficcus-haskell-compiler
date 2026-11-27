module Vector exposing (Vector(..), fromList)


type Vector a
    = Vector (List a) Int
    where
        compare : Vector a -> Vector a -> Order
        compare (Vector _ m) (Vector _ n) =
            Basics.compare m n


fromList : List a -> Vector a
fromList xs =
    Vector xs (List.length xs)
