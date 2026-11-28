module Main exposing (main)

import Dict
import Set


type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)
    where
        derive compare


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


lines : List String
lines =
    [ group "int" trees
    , group "string" strees
    , Debug.toString (List.map (\a -> List.map (\b -> Tree.compare a b) trees) trees)
    , Debug.toString ( List.maximum trees, List.minimum strees )
    , Debug.toString ( List.sort (List.take 4 trees), max (fromList [ 1 ]) Leaf )
    , Debug.toString ( compare (Just (fromList [ 1 ])) Nothing, compare [ Leaf, fromList [ 1 ] ] [ Leaf, Leaf ], ( fromList [ 2 ], 1 ) < ( fromList [ 2 ], 0 ) )
    , Debug.toString (Dict.values (Dict.fromList [ ( ( fromList [ 1 ], 2 ), "x" ), ( ( Leaf, 5 ), "y" ), ( ( fromList [ 1 ], 1 ), "z" ) ]))
    , Debug.toString (Node Leaf 1 Leaf < Leaf)
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
