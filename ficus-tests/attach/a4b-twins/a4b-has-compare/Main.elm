module Main exposing (main)



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


lines : List String
lines =
    [ Debug.toString (List.map (\l -> Maybe.withDefault -1 (List.head l)) (List.sort [ [ 3 ], [], [ 1 ], [] ]))
    , Debug.toString (List.map Tuple.first (List.sort [ ( 2, "x" ), ( 1, "z" ), ( 2, "a" ) ]))
    , Debug.toString (List.sort [ 2, 0, 1 ])
    , Debug.toString (List.sortWith cmpTree [ Node Leaf 2 Leaf, Leaf, Node (Node Leaf 1 Leaf) 0 Leaf ])
    , Debug.toString (List.sort [ [ 2 ], [], [ 0, 2 ] ])
    , Debug.toString (List.map (\( _, v, _ ) -> Maybe.withDefault 0 (List.head v)) (List.sort [ ( 1, [], [ "b" ] ), ( 0, [ 5 ], [] ), ( 0, [ 1 ], [] ) ]))
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
