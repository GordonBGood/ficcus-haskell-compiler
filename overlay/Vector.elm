module Vector exposing
    ( Vector
    , empty, withCapacity, fromList, toList
    , length, get
    , set, update, swap, push
    , slice, append
    )

{-| Ficcus: the flat `Vector` (decisions D1 to D8 of 12 Nov; docs/STAGE4-V1.md). THE MINIMAL MODULE OF STEP V1: only the primitives, so
that programs can be written for testing. V2 completes the API (`initialize`, `repeat`, `map`, `indexedMap`, `foldl`, `foldr`,
`filter`, `toIndexedList`, `isEmpty`, written in Elm on these) and the module rule.

A vector is an immutable value. Its elements are stored flat by layout: `Int`, `Float`, `Char`, `Bool` and records or tuples of
those inline, a reference as one pointer, a record or tuple that contains references inline with a pointer map. An update (`set`,
`update`, `swap`, `push`, `append`) is done in place when the vector has one owner and copies the whole vector otherwise; `push`
doubles the capacity.

The module is added to the source directories of `.c` and `.mono` builds (Ficcus.Mono.Overlay), so `import Vector` works there only.
The type is the built-in vector of the runtime (runtime/fic_vector.h): the compiler recognises it by the constructor below, keys every
function that touches the elements by the exact element type (Ficcus.Mono.Marks, `Element`), and replaces each function of the
first section by the kernel function `elm/core:Vector.<name>` (Ficcus.Mono.Kernel). Their bodies only give the types.

-}


{-| The constructor is never built: it marks the type as the built-in one.
-}
type Vector a
    = FicVectorBuiltin



-- KERNEL FUNCTIONS (types only)


{-| A vector without elements.
-}
empty : Vector a
empty =
    FicVectorBuiltin


{-| An empty vector with room for that many elements: `push` does not move it until it is full. (The allocation primitive that V2's
`initialize` and `repeat` are written with; the name is provisional.)
-}
withCapacity : Int -> Vector a
withCapacity n =
    withCapacity n


length : Vector a -> Int
length v =
    length v


{-| not exposed: the element at an index that is in range (`get` tests it)
-}
unsafeGet : Int -> Vector a -> a
unsafeGet i v =
    unsafeGet i v


{-| Replace the element at the index; out of range the vector is returned unchanged. In place when the vector has one owner.
-}
set : Int -> a -> Vector a -> Vector a
set i x v =
    set i x v


{-| Exchange the elements at two indices; the vector is returned unchanged when one of them is out of range.
-}
swap : Int -> Int -> Vector a -> Vector a
swap i j v =
    swap i j v


{-| Add an element at the end.
-}
push : a -> Vector a -> Vector a
push x v =
    push x v


{-| The elements from the first index up to, not including, the second, with the index rule of `Array.slice` (a negative index counts
from the end).
-}
slice : Int -> Int -> Vector a -> Vector a
slice from to v =
    slice from to v


append : Vector a -> Vector a -> Vector a
append a b =
    append a b


fromList : List a -> Vector a
fromList xs =
    fromList xs


toList : Vector a -> List a
toList v =
    toList v



-- IN ELM


{-| The element at the index, `Nothing` when it is out of range.
-}
get : Int -> Vector a -> Maybe a
get i v =
    if 0 <= i && i < length v then
        Just (unsafeGet i v)

    else
        Nothing


{-| Replace the element at the index by the result of the function; out of range the vector is returned unchanged. On a vector with
one owner the element is taken out, so the function gets it with one owner too, and the result is put back in place.
-}
update : Int -> (a -> a) -> Vector a -> Vector a
update i f v =
    if 0 <= i && i < length v then
        let
            x =
                unsafeGet i v
        in
        set i (f x) v

    else
        v
