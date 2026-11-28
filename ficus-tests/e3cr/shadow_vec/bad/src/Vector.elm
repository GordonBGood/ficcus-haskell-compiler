module Vector exposing (Vector, fromList, toList, length, map, sum)

-- a project module Vector (not the overlay): a record around a List, as a geometry or collection module might be


type Vector a
    = Vector { items : List a, n : Int }


fromList : List a -> Vector a
fromList l =
    Vector { items = l, n = List.length l }


toList : Vector a -> List a
toList (Vector r) =
    r.items


length : Vector a -> Int
length (Vector r) =
    r.n


map : (a -> b) -> Vector a -> Vector b
map f (Vector r) =
    Vector { items = List.map f r.items, n = r.n }


sum : Vector Int -> Int
sum (Vector r) =
    List.sum r.items
