module Vector exposing (Vector(..), fromList, compareV)


type Vector a
    = Vector (List a) Int


compareV : Vector a -> Vector a -> Order
compareV (Vector _ m) (Vector _ n) =
    Basics.compare m n


fromList : List a -> Vector a
fromList xs =
    Vector xs (List.length xs)
