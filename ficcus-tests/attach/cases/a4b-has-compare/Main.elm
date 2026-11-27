module Main exposing (main)



type Color
    = Red
    | Green
    | Blue
    where
        derive compare


type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)
    where
        derive compare


sortW : List a -> List a
    where
        a has compare : a -> a -> Order
sortW xs =
    List.sortWith compare xs


rank : Color -> Int
rank c =
    case c of
        Red ->
            0

        Green ->
            1

        Blue ->
            2


lines : List String
lines =
    [ Debug.toString (List.map (Maybe.withDefault -1) (sortW [ Just 3, Nothing, Just 1, Nothing ]))
    , Debug.toString (List.map .a (sortW [ { a = 2, b = "x" }, { a = 1, b = "z" }, { a = 2, b = "a" } ]))
    , Debug.toString (List.map rank (sortW [ Blue, Red, Green ]))
    , Debug.toString (sortW [ Node Leaf 2 Leaf, Leaf, Node (Node Leaf 1 Leaf) 0 Leaf ])
    , Debug.toString (List.map (List.map rank) (sortW [ [ Blue ], [], [ Red, Blue ] ]))
    , Debug.toString (List.map (Result.withDefault 0) (sortW [ Err "b", Ok 5, Ok 1 ]))
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
