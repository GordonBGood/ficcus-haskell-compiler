module Main exposing (main)

import Dict


-- a two-parameter lambda as the member value
type Lam
    = Lam Int
    where
        compare : Lam -> Lam -> Order
        compare =
            \(Lam a) (Lam b) -> Basics.compare (modBy 7 a) (modBy 7 b)

        eq : Lam -> Lam -> Bool
        eq =
            \(Lam a) (Lam b) -> modBy 7 a == modBy 7 b


-- a partial application (a closure value) as the member
type Part
    = Part Int String
    where
        compare : Part -> Part -> Order
        compare =
            by partKey

        eq : Part -> Part -> Bool
        eq =
            eqBy partKey


partKey : Part -> Int
partKey (Part n _) =
    n


by : (a -> Int) -> a -> a -> Order
by f x y =
    Basics.compare (f x) (f y)


eqBy : (a -> Int) -> a -> a -> Bool
eqBy f x y =
    f x == f y


-- a constant member (Known turns calls of it into the constant)
type Any
    = Any String
    where
        eq : Any -> Any -> Bool
        eq _ _ =
            True


-- a parameterized type with the member, used at two instances
type Tagged a
    = Tagged String a
    where
        eq : Tagged a -> Tagged a -> Bool
        eq (Tagged x _) (Tagged y _) =
            x == y


-- a member whose own body compares a container that holds the type (recursion through the helper)
type Tree
    = Node Lam (List Tree)
    where
        eq : Tree -> Tree -> Bool
        eq (Node a xs) (Node b ys) =
            a == b && xs == ys


same : a -> a -> Bool
same x y =
    x == y


lookup : comparable -> Dict.Dict comparable v -> Maybe v
lookup k d =
    Dict.get k d


lines : List String
lines =
    [ Debug.toString (( Lam 1, 0 ) == ( Lam 8, 0 ))
    , Debug.toString (compare [ Lam 1, Lam 9 ] [ Lam 8, Lam 3 ])
    , Debug.toString (List.sort [ ( Lam 13, "a" ), ( Lam 2, "b" ), ( Lam 7, "c" ) ] |> List.map Tuple.second)
    , Debug.toString ([ Part 1 "x" ] == [ Part 1 "y" ])
    , Debug.toString (( Part 2 "x", Part 1 "y" ) < ( Part 2 "z", Part 3 "w" ))
    , Debug.toString (Just (Any "a") == Just (Any "b"))
    , Debug.toString ([ Any "a" ] == [ Any "b", Any "c" ])
    , Debug.toString ([ Tagged "a" 1 ] == [ Tagged "a" 2 ])
    , Debug.toString (Just (Tagged "a" (Tagged "b" 1)) == Just (Tagged "a" (Tagged "c" 2)))
    , Debug.toString (Node (Lam 1) [ Node (Lam 2) [] ] == Node (Lam 8) [ Node (Lam 9) [] ])
    , Debug.toString ([ Node (Lam 1) [ Node (Lam 2) [] ] ] == [ Node (Lam 8) [ Node (Lam 3) [] ] ])
    , Debug.toString (same ( [], Lam 1 ) ( [], Lam 8 ))
    , Debug.toString (same ( Nothing, [ Part 1 "a" ] ) ( Nothing, [ Part 1 "b" ] ))
    , Debug.toString (lookup ( Lam 15, 0 ) (Dict.fromList [ ( ( Lam 1, 0 ), "found" ) ]))
    , Debug.toString (same (Dict.fromList [ ( 1, Lam 1 ) ]) (Dict.fromList [ ( 1, Lam 8 ) ]))
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
