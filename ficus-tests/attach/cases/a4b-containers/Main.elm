module Main exposing (main)

import Array exposing (Array)
import Dict exposing (Dict)
import Set exposing (Set)
import Vector exposing (Vector)


type Tag
    = Tag Int
    where
        derive compare


dictsOfSets : List (Dict (Maybe Int) (Set String))
dictsOfSets =
    [ Dict.fromList [ ( Just 1, Set.fromList [ "x" ] ) ], Dict.fromList [ ( Nothing, Set.empty ) ], Dict.fromList [ ( Just 1, Set.fromList [ "w", "x" ] ), ( Nothing, Set.empty ) ], Dict.fromList [ ( Just -1, Set.fromList [ "x" ] ) ] ]


maybes : List (Maybe Int)
maybes =
    [ Just 3, Nothing, Just -1, Just 3, Nothing, Just 0 ]


records : List { b : String, a : Int }
records =
    [ { a = 2, b = "x" }, { a = 1, b = "z" }, { b = "a", a = 2 }, { a = 1, b = "z" } ]


results : List (Result String Int)
results =
    [ Err "b", Ok 5, Err "a", Ok -2, Ok 5 ]


arrays : List (Array Int)
arrays =
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


vectors : List (Vector Int)
vectors =
    [ Vector.fromList [ 1, 2 ], Vector.fromList [], Vector.fromList [ 1 ], Vector.fromList [ 1, 2, 0 ], Vector.fromList [ 1, 2 ], Vector.fromList [ 0, 9, 9 ] ]


dicts : List (Dict String Int)
dicts =
    [ Dict.fromList [ ( "a", 1 ) ], Dict.empty, Dict.fromList [ ( "b", 0 ), ( "a", 1 ) ], Dict.fromList [ ( "a", 2 ) ], Dict.fromList [ ( "a", 1 ), ( "b", 0 ) ], Dict.fromList [ ( "a", 1 ), ( "b", -1 ) ] ]


sets : List (Set Int)
sets =
    [ Set.fromList [ 3, 1 ], Set.fromList [ 1 ], Set.empty, Set.fromList [ 1, 2, 3 ], Set.fromList [ 1, 3 ] ]


nested : List (Maybe (List ( Int, Maybe String )))
nested =
    [ Just [ ( 1, Nothing ) ], Nothing, Just [ ( 1, Just "a" ) ], Just [], Just [ ( 0, Just "z" ), ( 9, Nothing ) ], Just [ ( 1, Nothing ) ] ]


recs2 : List { arr : Array Int, m : Maybe { k : String } }
recs2 =
    [ { arr = Array.fromList [ 1 ], m = Nothing }, { arr = Array.fromList [ 1 ], m = Just { k = "b" } }, { arr = Array.empty, m = Just { k = "a" } } ]


floatsM : List (Maybe Float)
floatsM =
    [ Just (0 / 0), Just 0, Just -0.0, Nothing, Just 1, Just (1 / 0) ]


floatsR : List { x : Float, y : Int }
floatsR =
    [ { x = 0, y = 1 }, { x = -0.0, y = 1 }, { x = 0 / 0, y = 0 }, { x = -1 / 0, y = 2 } ]


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
    , Debug.toString ( compare (Just 1) Nothing, Just 2 < Just 10, max Nothing (Just -5) == Just -5 )
    , Debug.toString ( compare { a = 1, b = "x" } { a = 1, b = "y" }, { b = "z", a = 0 } < { a = 1, b = "a" } )
    , Debug.toString ( compare (Ok 1) (Err 0), compare (Err "a") (Err "b"), Ok 3 > Ok 2 )
    , Debug.toString ( Dict.get (Just 2) (Dict.fromList [ ( Just 2, "two" ), ( Nothing, "none" ) ]), List.map (Maybe.withDefault 99) (Dict.keys (Dict.fromList [ ( Just 2, "two" ), ( Nothing, "none" ), ( Just -1, "m" ) ])) )
    , Debug.toString ( Vector.fromList [ 1, 2 ] < Vector.fromList [ 1, 3 ], compare (Array.fromList [ 5 ]) (Array.fromList [ 4, 9 ]), compare (Set.fromList [ 2 ]) (Set.fromList [ 1, 3 ]) )
    , Debug.toString ( List.map (Maybe.withDefault -9) (List.sort maybes), List.map .a (List.sortBy identity records) )
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
