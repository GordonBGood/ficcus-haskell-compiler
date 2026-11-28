module Vector exposing
    ( Vector
    , empty, singleton, initialize, repeat, withCapacity, fromList, toList
    , isEmpty, length, get
    , set, update, swap, push
    , append, slice
    , map, indexedMap, foldl, foldr, filter, toIndexedList
    , sort, sortBy, sortWith
    )

{-| A stand-in for the Ficus module `Vector` (overlay/Vector.elm, V1) written on `Array`, so that a program that uses the Vector
primitives can be compiled and run by Elm 0.19.3: the reference output of the example `vec` comes from it, and `rcfuzz.py --elm-check`
uses it to check that the generated programs are valid Elm. It has the semantics of the primitives (decision D2: the `Array` API, an
out of range `set`, `update` or `swap` returns the vector unchanged) and none of the performance. `Debug.toString` of a vector is not
the same here (Ficus prints `Vector.fromList [..]`): compare lists.
-}

import Array exposing (Array)


type Vector a
    = Vector (Array a)


empty : Vector a
empty =
    Vector Array.empty


withCapacity : Int -> Vector a
withCapacity _ =
    Vector Array.empty


fromList : List a -> Vector a
fromList xs =
    Vector (Array.fromList xs)


toList : Vector a -> List a
toList (Vector a) =
    Array.toList a


length : Vector a -> Int
length (Vector a) =
    Array.length a


get : Int -> Vector a -> Maybe a
get i (Vector a) =
    Array.get i a


set : Int -> a -> Vector a -> Vector a
set i x (Vector a) =
    Vector (Array.set i x a)


update : Int -> (a -> a) -> Vector a -> Vector a
update i f (Vector a) =
    case Array.get i a of
        Just x ->
            Vector (Array.set i (f x) a)

        Nothing ->
            Vector a


swap : Int -> Int -> Vector a -> Vector a
swap i j (Vector a) =
    case ( Array.get i a, Array.get j a ) of
        ( Just x, Just y ) ->
            Vector (Array.set i y (Array.set j x a))

        _ ->
            Vector a


push : a -> Vector a -> Vector a
push x (Vector a) =
    Vector (Array.push x a)


slice : Int -> Int -> Vector a -> Vector a
slice from to (Vector a) =
    Vector (Array.slice from to a)


append : Vector a -> Vector a -> Vector a
append (Vector a) (Vector b) =
    Vector (Array.append a b)


singleton : a -> Vector a
singleton x =
    Vector (Array.fromList [ x ])


isEmpty : Vector a -> Bool
isEmpty (Vector a) =
    Array.isEmpty a


initialize : Int -> (Int -> a) -> Vector a
initialize n f =
    Vector (Array.initialize n f)


repeat : Int -> a -> Vector a
repeat n x =
    Vector (Array.repeat n x)


map : (a -> b) -> Vector a -> Vector b
map f (Vector a) =
    Vector (Array.map f a)


indexedMap : (Int -> a -> b) -> Vector a -> Vector b
indexedMap f (Vector a) =
    Vector (Array.indexedMap f a)


foldl : (a -> b -> b) -> b -> Vector a -> b
foldl f b (Vector a) =
    Array.foldl f b a


foldr : (a -> b -> b) -> b -> Vector a -> b
foldr f b (Vector a) =
    Array.foldr f b a


filter : (a -> Bool) -> Vector a -> Vector a
filter p (Vector a) =
    Vector (Array.filter p a)


toIndexedList : Vector a -> List ( Int, a )
toIndexedList (Vector a) =
    Array.toIndexedList a


sort : Vector comparable -> Vector comparable
sort v =
    fromList (List.sort (toList v))


sortBy : (a -> comparable) -> Vector a -> Vector a
sortBy f v =
    fromList (List.sortBy f (toList v))


sortWith : (a -> a -> Order) -> Vector a -> Vector a
sortWith f v =
    fromList (List.sortWith f (toList v))
