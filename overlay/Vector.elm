module Vector exposing
    ( Vector
    , empty, singleton, initialize, repeat, withCapacity, fromList, toList
    , isEmpty, length, get
    , set, update, swap, push
    , append, slice
    , map, indexedMap, foldl, foldr, filter, toIndexedList
    , sort, sortBy, sortWith
    )

{-| Ficcus: the flat `Vector` (decisions D1 to D8 of 12 Nov; docs/STAGE4-V1.md). The primitives of step V1 are the first section; the rest of the API of `Array`
(`singleton`, `initialize`, `repeat`, `isEmpty`, `map`, `indexedMap`, `foldl`, `foldr`, `filter`, `toIndexedList`; step V2) is written in
Elm on them, with the semantics of `Array` (an index out of range: `get` is `Nothing`, `set` returns the vector unchanged, a negative
length gives the empty vector), and the loops keep the vector that they build unique, so every `push` is in place.
Module rule: a module `Vector` of the project or of a package of the same name wins over this one (Build.crawlModule).

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


{-| not exposed: tells the compiler that this is the overlay's module and not a module `Vector` of the project or of a package
-}
ficVectorOverlay : Int
ficVectorOverlay =
    0


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


{-| not exposed: `set` for an index that is in range (`update` tests it): no range test on the fast path
-}
unsafeSet : Int -> a -> Vector a -> Vector a
unsafeSet i x v =
    unsafeSet i x v


{-| not exposed: `swap` for two indices that are in range (the loop of `filter` that reverses)
-}
unsafeSwap : Int -> Int -> Vector a -> Vector a
unsafeSwap i j v =
    unsafeSwap i j v


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


{-| Sort in ascending order (`compare`); stable. Powersort (runtime/fic_sort.h), in place when the vector has one owner and on a copy when
it is shared.
-}
sort : Vector comparable -> Vector comparable
sort v =
    sort v


{-| not exposed: the indices that sort the keys (stable): the permutation that `sortBy` applies
-}
sortPerm : Vector comparable -> Vector Int
sortPerm v =
    sortPerm v


{-| not exposed: the vector of Int sorted with a comparison function on the values (stable)
-}
sortIdx : (Int -> Int -> Order) -> Vector Int -> Vector Int
sortIdx f v =
    sortIdx f v



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
        unsafeSet i (f x) v

    else
        v


{-| A vector with one element.
-}
singleton : a -> Vector a
singleton x =
    push x (withCapacity 1)


isEmpty : Vector a -> Bool
isEmpty v =
    length v == 0


{-| `initialize n f` is the vector of `f 0` to `f (n - 1)`, evaluated in this order; the empty vector when `n` is not positive.
-}
initialize : Int -> (Int -> a) -> Vector a
initialize n f =
    if n <= 0 then
        empty

    else
        initializeHelp 0 n f (withCapacity n)


initializeHelp : Int -> Int -> (Int -> a) -> Vector a -> Vector a
initializeHelp i n f acc =
    if i >= n then
        acc

    else
        initializeHelp (i + 1) n f (push (f i) acc)


{-| `repeat n x` has `n` copies of `x`; the empty vector when `n` is not positive. (A kernel function: a fill loop.)
-}
repeat : Int -> a -> Vector a
repeat n x =
    repeat n x


map : (a -> b) -> Vector a -> Vector b
map f v =
    mapHelp 0 (length v) f v (withCapacity (length v))


mapHelp : Int -> Int -> (a -> b) -> Vector a -> Vector b -> Vector b
mapHelp i n f v acc =
    if i >= n then
        acc

    else
        mapHelp (i + 1) n f v (push (f (unsafeGet i v)) acc)


indexedMap : (Int -> a -> b) -> Vector a -> Vector b
indexedMap f v =
    indexedMapHelp 0 (length v) f v (withCapacity (length v))


indexedMapHelp : Int -> Int -> (Int -> a -> b) -> Vector a -> Vector b -> Vector b
indexedMapHelp i n f v acc =
    if i >= n then
        acc

    else
        indexedMapHelp (i + 1) n f v (push (f i (unsafeGet i v)) acc)


{-| Reduce from the first element to the last: `foldl f b v` is `f x_n (... (f x_1 b))`.
-}
foldl : (a -> b -> b) -> b -> Vector a -> b
foldl f acc v =
    foldlHelp 0 (length v) f acc v


foldlHelp : Int -> Int -> (a -> b -> b) -> b -> Vector a -> b
foldlHelp i n f acc v =
    if i >= n then
        acc

    else
        foldlHelp (i + 1) n f (f (unsafeGet i v) acc) v


{-| Reduce from the last element to the first.
-}
foldr : (a -> b -> b) -> b -> Vector a -> b
foldr f acc v =
    foldrHelp (length v - 1) f acc v


foldrHelp : Int -> (a -> b -> b) -> b -> Vector a -> b
foldrHelp i f acc v =
    if i < 0 then
        acc

    else
        foldrHelp (i - 1) f (f (unsafeGet i v) acc) v


{-| The elements for which the function is `True`, in order. As `Array.filter` (a right fold) the function is called from the last
element to the first (only `Debug.log` can tell); the kept elements are pushed in that order and the vector is reversed in place.
-}
filter : (a -> Bool) -> Vector a -> Vector a
filter p v =
    reverseInPlace 0 (filterHelp (length v - 1) p v empty)


filterHelp : Int -> (a -> Bool) -> Vector a -> Vector a -> Vector a
filterHelp i p v acc =
    if i < 0 then
        acc

    else
        let
            x =
                unsafeGet i v
        in
        filterHelp (i - 1) p v (if p x then push x acc else acc)


reverseInPlace : Int -> Vector a -> Vector a
reverseInPlace i v =
    let
        j =
            length v - 1 - i
    in
    if i >= j then
        v

    else
        reverseInPlace (i + 1) (unsafeSwap i j v)


{-| The elements with their indices, in order.
-}
toIndexedList : Vector a -> List ( Int, a )
toIndexedList v =
    toIndexedHelp (length v - 1) v []


toIndexedHelp : Int -> Vector a -> List ( Int, a ) -> List ( Int, a )
toIndexedHelp i v acc =
    if i < 0 then
        acc

    else
        toIndexedHelp (i - 1) v (( i, unsafeGet i v ) :: acc)


{-| Sort by the key of each element; stable. Unlike `List.sortBy` of elm/core in JavaScript, which calls the function at each comparison, the
key of every element is computed exactly once (n calls), also for an element that is never compared.
-}
sortBy : (a -> comparable) -> Vector a -> Vector a
sortBy f v =
    if length v < 2 then
        v

    else
        permute v (sortPerm (map f v))


{-| Sort with a comparison function; stable. A kernel (H21d): the elements are sorted in place (unique vector) or in a copy, the function is
called on copies of the two elements (the closure consumes its arguments).
-}
sortWith : (a -> a -> Order) -> Vector a -> Vector a
sortWith cmp v =
    sortWith cmp v


{-| not exposed: `sort` for an element type that has a `compare` member (a custom type with its own `compare`, or Word64): the comparison
is the member, so the kernel (which compares structurally) is not used (the specializer redirects `sort` to this for such types)
-}
sortMember : Vector comparable -> Vector comparable
sortMember v =
    sortWith compare v


{-| not exposed: `sortPerm` for such an element type; stable like the kernel
-}
sortPermMember : Vector comparable -> Vector Int
sortPermMember keys =
    sortIdx (\i j -> compare (unsafeGet i keys) (unsafeGet j keys)) (initialize (length keys) identity)


{-| not exposed: the elements in the order of the indices
-}
permute : Vector a -> Vector Int -> Vector a
permute v idx =
    permuteHelp 0 (length idx) v idx (withCapacity (length idx))


permuteHelp : Int -> Int -> Vector a -> Vector Int -> Vector a -> Vector a
permuteHelp k n v idx acc =
    if k >= n then
        acc

    else
        permuteHelp (k + 1) n v idx (push (unsafeGet (unsafeGet k idx) v) acc)
