module FicOverlaySort exposing (..)

{-| Ficcus: the sorts of elm/core (List.sort, sortBy, sortWith) in the C path. Two variants of this module are embedded (Ficcus.Mono.Overlay) and
`writeOverlay` (terminal/src/Make.hs) writes one of them: this one, on the flat Vector (Powersort, runtime/fic_sort.h), or, when the project has a
module of its own named `Vector` (which wins over the overlay's), the one that is written in Elm on lists (overlay/FicOverlaySortList.elm).
-}

import Vector


{-| H21: the C path sorts a list by turning it into a Vector, sorting that (Powersort, runtime/fic_sort.h) and turning it back. Stable.
The key function of `sortBy` is called once per element (n calls), where elm/core in JavaScript calls it at each comparison: a difference that
is only visible with a key function that has an effect, such as Debug.log. -}
listSort : List comparable -> List comparable
listSort xs =
    Vector.toList (Vector.sort (Vector.fromList xs))


listSortBy : (a -> comparable) -> List a -> List a
listSortBy f xs =
    Vector.toList (Vector.sortBy f (Vector.fromList xs))


listSortWith : (a -> a -> Order) -> List a -> List a
listSortWith cmp xs =
    Vector.toList (Vector.sortWith cmp (Vector.fromList xs))
