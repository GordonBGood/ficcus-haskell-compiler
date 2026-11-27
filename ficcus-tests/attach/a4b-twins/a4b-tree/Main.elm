module Main exposing (main)

import Dict
import Set


type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)


cmpTree : Tree comparable -> Tree comparable -> Order
cmpTree a b =
    case ( a, b ) of
        ( Leaf, Leaf ) ->
            EQ

        ( Leaf, _ ) ->
            LT

        ( _, Leaf ) ->
            GT

        ( Node l1 v1 r1, Node l2 v2 r2 ) ->
            case cmpTree l1 l2 of
                EQ ->
                    case compare v1 v2 of
                        EQ ->
                            cmpTree r1 r2

                        o ->
                            o

                o ->
                    o


cmpList : (a -> a -> Order) -> List a -> List a -> Order
cmpList cmp xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            EQ

        ( [], _ ) ->
            LT

        ( _, [] ) ->
            GT

        ( x :: xr, y :: yr ) ->
            case cmp x y of
                EQ ->
                    cmpList cmp xr yr

                o ->
                    o


insert : comparable -> Tree comparable -> Tree comparable
insert x t =
    case t of
        Leaf ->
            Node Leaf x Leaf

        Node l v r ->
            if x < v then
                Node (insert x l) v r

            else
                Node l v (insert x r)


fromList : List comparable -> Tree comparable
fromList xs =
    List.foldl insert Leaf xs


trees : List (Tree Int)
trees =
    [ Leaf, fromList [ 2, 1, 3 ], fromList [ 1, 2, 3 ], fromList [ 2, 1 ], fromList [ 2, 1, 3 ], Node Leaf 5 Leaf, fromList [ 3 ], fromList [ 2, 3 ] ]


strees : List (Tree String)
strees =
    [ fromList [ "b", "a" ], fromList [ "a" ], Leaf, fromList [ "b" ], fromList [ "b", "c" ] ]


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


lines : List String
lines =
    [ groupW "int" cmpTree trees
    , groupW "string" cmpTree strees
    , Debug.toString (List.map (\a -> List.map (\b -> cmpTree a b) trees) trees)
    , Debug.toString ( maxA cmpTree trees, maxA (\a b -> cmpTree b a) strees )
    , Debug.toString ( List.sortWith cmpTree (List.take 4 trees), Maybe.withDefault Leaf (maxA cmpTree [ fromList [ 1 ], Leaf ]) )
    , Debug.toString ( cmpList cmpTree [ fromList [ 1 ] ] [], cmpList cmpTree [ Leaf, fromList [ 1 ] ] [ Leaf, Leaf ], (case cmpTree (fromList [ 2 ]) (fromList [ 2 ]) of
                                                                                                                          EQ -> compare 1 0
                                                                                                                          o -> o) == LT )
    , Debug.toString (List.map Tuple.second (assoc (\( t1, n1 ) ( t2, n2 ) -> case cmpTree t1 t2 of
                                                                                EQ -> compare n1 n2
                                                                                o -> o) [ ( ( fromList [ 1 ], 2 ), "x" ), ( ( Leaf, 5 ), "y" ), ( ( fromList [ 1 ], 1 ), "z" ) ]))
    , Debug.toString (cmpTree (Node Leaf 1 Leaf) Leaf == LT)
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
