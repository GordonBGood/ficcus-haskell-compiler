module Main exposing (main)

import Array
import Dict
import Set


mb : Maybe a -> List a
mb m =
    case m of
        Nothing ->
            []

        Just x ->
            [ x ]


res : Result e a -> ( Int, List a, List e )
res r =
    case r of
        Ok v ->
            ( 0, [ v ], [] )

        Err e ->
            ( 1, [], [ e ] )


dictsOfSets : List (List ( List Int, List String ))
dictsOfSets =
    List.map (\kvs -> Dict.toList (Dict.fromList (List.map (\( k, v ) -> ( mb k, Set.toList v )) kvs)))
        [ [ ( Just 1, Set.fromList [ "x" ] ) ], [ ( Nothing, Set.empty ) ], [ ( Just 1, Set.fromList [ "w", "x" ] ), ( Nothing, Set.empty ) ], [ ( Just -1, Set.fromList [ "x" ] ) ] ]


maybes : List (List Int)
maybes =
    List.map mb [ Just 3, Nothing, Just -1, Just 3, Nothing, Just 0 ]


records : List ( Int, String )
records =
    List.map (\r -> ( r.a, r.b )) [ { a = 2, b = "x" }, { a = 1, b = "z" }, { b = "a", a = 2 }, { a = 1, b = "z" } ]


results : List ( Int, List Int, List String )
results =
    List.map res [ Err "b", Ok 5, Err "a", Ok -2, Ok 5 ]


arrays : List (List Int)
arrays =
    List.map Array.toList
    [ Array.fromList [ 1, 2 ]
    , Array.empty
    , Array.fromList [ 1 ]
    , Array.fromList (List.range 1 40)
    , Array.fromList (List.range 1 39 ++ [ 0 ])
    , Array.initialize 70 identity
    , Array.push 7 (Array.fromList (List.range 0 68))
    , Array.fromList (List.range 1 40)
    , Array.fromList (List.range 0 1100)
    , Array.set 1099 5 (Array.fromList (List.range 0 1100))
    ]


vectors : List (List Int)
vectors =
    [ [ 1, 2 ], [], [ 1 ], [ 1, 2, 0 ], [ 1, 2 ], [ 0, 9, 9 ] ]


dicts : List (List ( String, Int ))
dicts =
    List.map Dict.toList [ Dict.fromList [ ( "a", 1 ) ], Dict.empty, Dict.fromList [ ( "b", 0 ), ( "a", 1 ) ], Dict.fromList [ ( "a", 2 ) ], Dict.fromList [ ( "a", 1 ), ( "b", 0 ) ], Dict.fromList [ ( "a", 1 ), ( "b", -1 ) ] ]


sets : List (List Int)
sets =
    List.map Set.toList [ Set.fromList [ 3, 1 ], Set.fromList [ 1 ], Set.empty, Set.fromList [ 1, 2, 3 ], Set.fromList [ 1, 3 ] ]


nested : List (List (List ( Int, List String )))
nested =
    List.map (\m -> mb (Maybe.map (List.map (\( i, s ) -> ( i, mb s ))) m)) [ Just [ ( 1, Nothing ) ], Nothing, Just [ ( 1, Just "a" ) ], Just [], Just [ ( 0, Just "z" ), ( 9, Nothing ) ], Just [ ( 1, Nothing ) ] ]


recs2 : List ( List Int, List String )
recs2 =
    List.map (\r -> ( Array.toList r.arr, mb (Maybe.map .k r.m) )) [ { arr = Array.fromList [ 1 ], m = Nothing }, { arr = Array.fromList [ 1 ], m = Just { k = "b" } }, { arr = Array.empty, m = Just { k = "a" } } ]


floatsM : List (List Float)
floatsM =
    List.map mb [ Just (0 / 0), Just 0, Just -0.0, Nothing, Just 1, Just (1 / 0) ]


floatsR : List ( Float, Int )
floatsR =
    List.map (\r -> ( r.x, r.y )) [ { x = 0, y = 1 }, { x = -0.0, y = 1 }, { x = 0 / 0, y = 0 }, { x = -1 / 0, y = 2 } ]


indexed : List a -> List ( a, Int )
indexed xs =
    List.indexedMap (\i x -> ( x, i )) xs


group : String -> List comparable -> String
group label xs =
    label
        ++ " "
        ++ Debug.toString
            ( ( List.map (\a -> List.map (\b -> compare a b) xs) xs
              , List.map (\a -> List.map (\b -> ( a < b, a >= b )) xs) xs
              )
            , ( List.map Tuple.second (List.sortBy Tuple.first (indexed xs))
              , Dict.values (Dict.fromList (indexed xs))
              , Set.size (Set.fromList xs)
              )
            , Maybe.map (\m -> List.map Tuple.second (List.filter (\( x, _ ) -> compare x m == EQ) (indexed xs))) (List.maximum xs)
            )


orders : String -> List comparable -> String
orders label xs =
    label
        ++ " "
        ++ Debug.toString
            ( List.map (\a -> List.map (\b -> compare a b) xs) xs
            , List.map (\a -> List.map (\b -> ( a < b, a > b )) xs) xs
            )


lines : List String
lines =
    [ group "maybe" maybes
    , group "record" records
    , group "result" results
    , group "array" arrays
    , group "vector" vectors
    , group "dict" dicts
    , group "set" sets
    , group "nested" nested
    , group "recs2" recs2
    , group "dictsOfSets" dictsOfSets
    , orders "floatsM" floatsM
    , orders "floatsR" floatsR
    , Debug.toString ( compare [ 1 ] [], [ 2 ] < [ 10 ], max [] [ -5 ] == [ -5 ] )
    , Debug.toString ( compare ( 1, "x" ) ( 1, "y" ), ( 0, "z" ) < ( 1, "a" ) )
    , Debug.toString ( compare ( 0, [ 1 ], [] ) ( 1, [], [ 0 ] ), compare ( 1, [], [ "a" ] ) ( 1, [], [ "b" ] ), ( 0, [ 3 ], [] ) > ( 0, [ 2 ], [] ) )
    , Debug.toString ( Maybe.map List.head (Dict.get [ 2 ] (Dict.fromList [ ( [ 2 ], [ "two" ] ), ( [], [ "none" ] ) ])) |> Maybe.andThen identity, List.map (\k -> Maybe.withDefault 99 (List.head k)) (Dict.keys (Dict.fromList [ ( [ 2 ], "two" ), ( [], "none" ), ( [ -1 ], "m" ) ])) )
    , Debug.toString ( [ 1, 2 ] < [ 1, 3 ], compare [ 5 ] [ 4, 9 ], compare [ 2 ] [ 1, 3 ] )
    , Debug.toString ( List.map (\l -> Maybe.withDefault -9 (List.head l)) (List.sort maybes), List.map Tuple.first (List.sortBy identity records) )
    ]


logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> let _ = logAll lines in ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
