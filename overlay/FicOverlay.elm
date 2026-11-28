module FicOverlay exposing (..)

{-| Ficus: elm/core functions that are written in JavaScript (`Elm.Kernel.*`) in the real library and
here in Elm, so that the specializer clones them per class like any other definition.
The compiler adds this module to every `.c` and `.mono` build and redirects the kernel id
(`elm/core:List.map2` ...) to the definition named in Ficus.Mono.Overlay. The type annotations are
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


{-| Ficus (ATTACH A3): `<`, `>`, `<=`, `>=` and `/=` at a custom type that has the member `compare` (or `eq`) are these
definitions: the specializer redirects the kernel function to them for such a type only (the primitives are used for
every other type). `compare` and `==` inside are the member calls. -}
ficLt : comparable -> comparable -> Bool
ficLt a b =
    compare a b == LT


ficGt : comparable -> comparable -> Bool
ficGt a b =
    compare a b == GT


ficLe : comparable -> comparable -> Bool
ficLe a b =
    compare a b /= GT


ficGe : comparable -> comparable -> Bool
ficGe a b =
    compare a b /= LT


ficNeq : a -> a -> Bool
ficNeq a b =
    not (a == b)



-- A4c: the enumeration members of the built-in types Bool, Order (all five, declaration order: False < True as A4b's
-- `compare`, LT < EQ < GT) and Int (`minValue`, `maxValue`); Ficus.Mono.BuiltinMembers maps a member to these.


ficBoolMinValue : Bool
ficBoolMinValue =
    False


ficBoolMaxValue : Bool
ficBoolMaxValue =
    True


ficBoolSucc : Bool -> Maybe Bool
ficBoolSucc b =
    if b then
        Nothing

    else
        Just True


ficBoolPred : Bool -> Maybe Bool
ficBoolPred b =
    if b then
        Just False

    else
        Nothing


ficBoolEnumerate : List Bool
ficBoolEnumerate =
    [ False, True ]


ficOrderMinValue : Order
ficOrderMinValue =
    LT


ficOrderMaxValue : Order
ficOrderMaxValue =
    GT


ficOrderSucc : Order -> Maybe Order
ficOrderSucc o =
    case o of
        LT ->
            Just EQ

        EQ ->
            Just GT

        GT ->
            Nothing


ficOrderPred : Order -> Maybe Order
ficOrderPred o =
    case o of
        LT ->
            Nothing

        EQ ->
            Just LT

        GT ->
            Just EQ


ficOrderEnumerate : List Order
ficOrderEnumerate =
    [ LT, EQ, GT ]


ficIntMinValue : Int
ficIntMinValue =
    -9223372036854775807 - 1


ficIntMaxValue : Int
ficIntMaxValue =
    9223372036854775807
