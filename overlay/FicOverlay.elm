module FicOverlay exposing (..)

{-| Ficcus: elm/core functions that are written in JavaScript (`Elm.Kernel.*`) in the real library and
here in Elm, so that the specializer clones them per class like any other definition.
The compiler adds this module to every `.c` and `.mono` build and redirects the kernel id
(`elm/core:List.map2` ...) to the definition named in Ficcus.Mono.Overlay. The type annotations are
the ones of elm/core (same variable names, same order): the call site's instance is matched against them.

Rules: results and the order of evaluation equal the JavaScript kernels (first to last element,
the shorter list ends the result); no function here recurses deeper than a few calls per list length
(lists are built reversed and turned around).
-}


listMap2 : (a -> b -> result) -> List a -> List b -> List result
listMap2 f xs ys =
    map2Help f xs ys []


map2Help : (a -> b -> result) -> List a -> List b -> List result -> List result
map2Help f xs ys acc =
    case xs of
        [] ->
            List.reverse acc

        x :: xr ->
            case ys of
                [] ->
                    List.reverse acc

                y :: yr ->
                    map2Help f xr yr (f x y :: acc)


listMap3 : (a -> b -> c -> result) -> List a -> List b -> List c -> List result
listMap3 f xs ys zs =
    map3Help f xs ys zs []


map3Help : (a -> b -> c -> result) -> List a -> List b -> List c -> List result -> List result
map3Help f xs ys zs acc =
    case ( xs, ys, zs ) of
        ( x :: xr, y :: yr, z :: zr ) ->
            map3Help f xr yr zr (f x y z :: acc)

        _ ->
            List.reverse acc


listMap4 : (a -> b -> c -> d -> result) -> List a -> List b -> List c -> List d -> List result
listMap4 f ws xs ys zs =
    map4Help f ws xs ys zs []


map4Help : (a -> b -> c -> d -> result) -> List a -> List b -> List c -> List d -> List result -> List result
map4Help f ws xs ys zs acc =
    case ws of
        [] ->
            List.reverse acc

        w :: wr ->
            case xs of
                [] ->
                    List.reverse acc

                x :: xr ->
                    case ys of
                        [] ->
                            List.reverse acc

                        y :: yr ->
                            case zs of
                                [] ->
                                    List.reverse acc

                                z :: zr ->
                                    map4Help f wr xr yr zr (f w x y z :: acc)


listMap5 : (a -> b -> c -> d -> e -> result) -> List a -> List b -> List c -> List d -> List e -> List result
listMap5 f vs ws xs ys zs =
    map5Help f vs ws xs ys zs []


map5Help : (a -> b -> c -> d -> e -> result) -> List a -> List b -> List c -> List d -> List e -> List result -> List result
map5Help f vs ws xs ys zs acc =
    case vs of
        [] ->
            List.reverse acc

        v :: vr ->
            case ws of
                [] ->
                    List.reverse acc

                w :: wr ->
                    case xs of
                        [] ->
                            List.reverse acc

                        x :: xr ->
                            case ys of
                                [] ->
                                    List.reverse acc

                                y :: yr ->
                                    case zs of
                                        [] ->
                                            List.reverse acc

                                        z :: zr ->
                                            map5Help f vr wr xr yr zr (f v w x y z :: acc)


listIndexedMap : (Int -> a -> b) -> List a -> List b
listIndexedMap f xs =
    indexedMapHelp f 0 xs []


indexedMapHelp : (Int -> a -> b) -> Int -> List a -> List b -> List b
indexedMapHelp f i xs acc =
    case xs of
        [] ->
            List.reverse acc

        x :: xr ->
            indexedMapHelp f (i + 1) xr (f i x :: acc)


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
