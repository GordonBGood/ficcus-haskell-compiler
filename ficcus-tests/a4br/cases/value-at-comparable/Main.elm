module Main exposing (main)


type Color
    = Red
    | Green
    | Blue
    where
        derive compare, hash


type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)
    where
        derive compare, hash


ts : List (Tree String)
ts =
    [ Node Leaf "b" Leaf, Leaf, Node (Node Leaf "a" Leaf) "a" Leaf, Node Leaf "a" Leaf ]


type alias Ops a =
    { cmp : a -> a -> Order, h : a -> Int }


ops : Ops (Tree String)
ops =
    { cmp = Tree.compare, h = Tree.hash }


apply2 : (a -> a -> Order) -> a -> a -> Order
apply2 f x y =
    f x y


sortTrees : List (Tree comparable) -> List (Tree comparable)
sortTrees =
    List.sortWith Tree.compare


lines : List String
lines =
    [ Debug.toString ( sortTrees ts, sortTrees [ Node Leaf 3 Leaf, Leaf ] ) ]


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
