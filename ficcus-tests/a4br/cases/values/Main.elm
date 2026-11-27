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


lines : List String
lines =
    let
        c =
            Tree.compare

        partial =
            Tree.compare (Node Leaf "a" Leaf)
    in
    [ Debug.toString (List.sortWith c ts)
    , Debug.toString (List.sortWith ops.cmp ts)
    , Debug.toString (List.map partial ts)
    , Debug.toString (List.map ops.h ts |> List.map (\h -> h == ops.h Leaf))
    , Debug.toString (List.map Color.hash [ Red, Green, Blue ] |> List.map (\h -> h == Color.hash Green))
    , Debug.toString (apply2 Color.compare Blue Red, apply2 Tree.compare Leaf (Node Leaf "x" Leaf))
    , Debug.toString (List.map2 Tree.compare ts (List.reverse ts))
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
