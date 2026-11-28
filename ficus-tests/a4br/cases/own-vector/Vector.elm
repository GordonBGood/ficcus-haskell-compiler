module Vector exposing (Vector(..), fromList)


type Vector a
    = Vector (List a) Int


fromList : List a -> Vector a
fromList xs =
    Vector xs (List.length xs)
