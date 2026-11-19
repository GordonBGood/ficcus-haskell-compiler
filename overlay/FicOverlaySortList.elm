module FicOverlaySort exposing (..)

{-| Ficcus: the sorts of elm/core (List.sort, sortBy, sortWith) in the C path. THE LIST VARIANT (used when the project has a module `Vector` of its own). Two variants of this module are embedded (Ficcus.Mono.Overlay) and
`writeOverlay` (terminal/src/Make.hs) writes one of them: this one, on the flat Vector (Powersort, runtime/fic_sort.h), or, when the project has a
module of its own named `Vector` (which wins over the overlay's), the one that is written in Elm on lists (overlay/FicOverlaySortList.elm).
-}

listSort : List comparable -> List comparable
listSort xs =
    listSortBy identity xs


{-| The key function is called once per element (elm/core calls it once per comparison: an accepted
difference, only visible with a key function that has an effect such as Debug.log). Stable. -}
listSortBy : (a -> comparable) -> List a -> List a
listSortBy f xs =
    List.map Tuple.second (listSortWith keyOrder (List.map (\x -> ( f x, x )) xs))


keyOrder : ( comparable, a ) -> ( comparable, a ) -> Order
keyOrder ( a, _ ) ( b, _ ) =
    compare a b


{-| A stable merge sort: halves of the list are sorted and merged, an element of the left half goes first
when the two are equal. -}
listSortWith : (a -> a -> Order) -> List a -> List a
listSortWith cmp xs =
    sortN cmp (List.length xs) xs


sortN : (a -> a -> Order) -> Int -> List a -> List a
sortN cmp n xs =
    if n < 2 then
        xs

    else
        let
            h =
                n // 2

            ( left, right ) =
                splitAt h xs []
        in
        mergeLists cmp (sortN cmp h left) (sortN cmp (n - h) right) []


splitAt : Int -> List a -> List a -> ( List a, List a )
splitAt n xs acc =
    if n <= 0 then
        ( List.reverse acc, xs )

    else
        case xs of
            [] ->
                ( List.reverse acc, [] )

            x :: rest ->
                splitAt (n - 1) rest (x :: acc)


mergeLists : (a -> a -> Order) -> List a -> List a -> List a -> List a
mergeLists cmp ls rs acc =
    case ls of
        [] ->
            List.foldl (::) rs acc

        l :: lr ->
            case rs of
                [] ->
                    List.foldl (::) ls acc

                r :: rr ->
                    case cmp l r of
                        GT ->
                            mergeLists cmp ls rr (r :: acc)

                        _ ->
                            mergeLists cmp lr rs (l :: acc)
