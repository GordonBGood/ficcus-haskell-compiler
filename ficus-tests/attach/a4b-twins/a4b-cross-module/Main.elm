module Main exposing (main)

import Dict
import Set


type Shape
    = Circle Float
    | Square Int
    | Dot


enc : Shape -> ( Int, Float, Int )
enc s =
    case s of
        Circle r ->
            ( 0, r, 0 )

        Square n ->
            ( 1, 0, n )

        Dot ->
            ( 2, 0, 0 )


shapes : List Shape
shapes =
    [ Square 2, Circle 1.5, Dot, Circle -0.0, Square 1, Circle 0, Dot ]


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


assoc : (k -> k -> Order) -> List ( k, v ) -> List ( k, v )
assoc cmp kvs =
    List.foldl (\( k, v ) acc -> insertA cmp k v acc) [] kvs


insertA : (k -> k -> Order) -> k -> v -> List ( k, v ) -> List ( k, v )
insertA cmp k v acc =
    case acc of
        [] ->
            [ ( k, v ) ]

        ( k2, v2 ) :: rest ->
            case cmp k k2 of
                LT ->
                    ( k, v ) :: acc

                EQ ->
                    ( k, v ) :: rest

                GT ->
                    ( k2, v2 ) :: insertA cmp k v rest


setA : (k -> k -> Order) -> List k -> List k
setA cmp xs =
    List.map Tuple.first (assoc cmp (List.map (\x -> ( x, () )) xs))


maxA : (a -> a -> Order) -> List a -> Maybe a
maxA cmp xs =
    List.foldl (\x m -> case m of
                            Nothing -> Just x
                            Just y -> if cmp x y == GT then Just x else Just y) Nothing xs


groupW : String -> (a -> a -> Order) -> List a -> String
groupW label cmp xs =
    label
        ++ " "
        ++ Debug.toString
            ( ( List.map (\a -> List.map (\b -> cmp a b) xs) xs
              , List.map (\a -> List.map (\b -> ( cmp a b == LT, cmp a b /= LT )) xs) xs
              )
            , ( List.map Tuple.second (List.sortWith (\( a, _ ) ( b, _ ) -> cmp a b) (indexed xs))
              , List.map Tuple.second (assoc cmp (indexed xs))
              , List.length (setA cmp xs)
              )
            , Maybe.map (\m -> List.map Tuple.second (List.filter (\( x, _ ) -> cmp x m == EQ) (indexed xs))) (maxA cmp xs)
            )


cmpS : Shape -> Shape -> Order
cmpS a b =
    compare (enc a) (enc b)


lines : List String
lines =
    [ groupW "shape" cmpS shapes
    , Debug.toString (Set.toList (Set.fromList [ "c@x", "a@x", "b@x", "a@x" ]))
    , Debug.toString (assoc cmpS (List.map (\s -> ( s, 1 )) shapes))
    , Debug.toString ( cmpS Dot (Square 9), cmpS (Circle 2) (Circle 1), Circle 0 == Circle -0.0 )
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
