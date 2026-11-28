module Vector exposing (Vector, fromList, length)

-- a project module Vector (not the overlay): a record around a List


type Vector a
    = Vector { items : List a, n : Int }


fromList : List a -> Vector a
fromList l =
    Vector { items = l, n = List.length l }


length : Vector a -> Int
length (Vector r) =
    r.n
