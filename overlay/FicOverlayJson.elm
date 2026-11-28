module FicOverlayJson exposing
    ( arrayFrom, objectFrom, objectKeys, objectValues, arrayAsList
    , encodeList, encodeArray, encodeSet, encodeObject, encodeDict
    , array, keyValuePairs, map3, map4, map5, map6, map7, map8
    )

{-| Ficus: the part of elm/json that is written in Elm on top of the kernel (runtime/fic_json.h). Compiled only into projects
that depend directly on elm/json (Ficus.Mono.Overlay); the specializer redirects `Json.Encode.list`, `array`, `set`, `object`,
`dict` and `Json.Decode.array`, `keyValuePairs`, `map3` to `map8` to the functions below (same types).

The first five definitions only give the types: they are kernel functions (`author/project:FicOverlayJson.<name>` in
Ficus.Mono.Kernel), their bodies are never compiled to C.

-}

import Array exposing (Array)
import Dict exposing (Dict)
import Json.Decode as D exposing (Decoder)
import Json.Encode as E exposing (Value)
import Set exposing (Set)



-- KERNEL FUNCTIONS (types only)


{-| a Json array of the values of a list
-}
arrayFrom : List Value -> Value
arrayFrom _ =
    E.null


{-| a Json object of keys and values (two lists of the same length); a key that occurs again replaces the value
-}
objectFrom : List String -> List Value -> Value
objectFrom _ _ =
    E.null


{-| the keys of a Json object, in order (fails with "Expecting an OBJECT")
-}
objectKeys : Decoder (List String)
objectKeys =
    D.succeed []


{-| the values of a Json object, in order, each decoded (a failure is `Field key error`)
-}
objectValues : Decoder a -> Decoder (List a)
objectValues decoder =
    D.list decoder


{-| `Json.Decode.list` with the message of `Json.Decode.array` ("Expecting an ARRAY")
-}
arrayAsList : Decoder a -> Decoder (List a)
arrayAsList decoder =
    D.list decoder



-- JSON.ENCODE


encodeList : (a -> Value) -> List a -> Value
encodeList func entries =
    arrayFrom (List.map func entries)


encodeArray : (a -> Value) -> Array a -> Value
encodeArray func entries =
    arrayFrom (List.map func (Array.toList entries))


encodeSet : (a -> Value) -> Set a -> Value
encodeSet func entries =
    arrayFrom (List.map func (Set.toList entries))


encodeObject : List ( String, Value ) -> Value
encodeObject pairs =
    objectFrom (List.map Tuple.first pairs) (List.map Tuple.second pairs)


encodeDict : (k -> String) -> (v -> Value) -> Dict k v -> Value
encodeDict toKey toValue dictionary =
    encodeObject (List.reverse (Dict.foldl (\key value acc -> ( toKey key, toValue value ) :: acc) [] dictionary))



-- JSON.DECODE


array : Decoder a -> Decoder (Array a)
array decoder =
    D.map Array.fromList (arrayAsList decoder)


keyValuePairs : Decoder a -> Decoder (List ( String, a ))
keyValuePairs decoder =
    D.map2 (List.map2 Tuple.pair) objectKeys (objectValues decoder)


map3 : (a -> b -> c -> value) -> Decoder a -> Decoder b -> Decoder c -> Decoder value
map3 f d1 d2 d3 =
    D.map2 (<|) (D.map2 f d1 d2) d3


map4 : (a -> b -> c -> d -> value) -> Decoder a -> Decoder b -> Decoder c -> Decoder d -> Decoder value
map4 f d1 d2 d3 d4 =
    D.map2 (<|) (map3 f d1 d2 d3) d4


map5 : (a -> b -> c -> d -> e -> value) -> Decoder a -> Decoder b -> Decoder c -> Decoder d -> Decoder e -> Decoder value
map5 f d1 d2 d3 d4 d5 =
    D.map2 (<|) (map4 f d1 d2 d3 d4) d5


map6 : (a -> b -> c -> d -> e -> f -> value) -> Decoder a -> Decoder b -> Decoder c -> Decoder d -> Decoder e -> Decoder f -> Decoder value
map6 f d1 d2 d3 d4 d5 d6 =
    D.map2 (<|) (map5 f d1 d2 d3 d4 d5) d6


map7 : (a -> b -> c -> d -> e -> f -> g -> value) -> Decoder a -> Decoder b -> Decoder c -> Decoder d -> Decoder e -> Decoder f -> Decoder g -> Decoder value
map7 f d1 d2 d3 d4 d5 d6 d7 =
    D.map2 (<|) (map6 f d1 d2 d3 d4 d5 d6) d7


map8 : (a -> b -> c -> d -> e -> f -> g -> h -> value) -> Decoder a -> Decoder b -> Decoder c -> Decoder d -> Decoder e -> Decoder f -> Decoder g -> Decoder h -> Decoder value
map8 f d1 d2 d3 d4 d5 d6 d7 d8 =
    D.map2 (<|) (map7 f d1 d2 d3 d4 d5 d6 d7) d8
