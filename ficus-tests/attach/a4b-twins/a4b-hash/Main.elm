module Main exposing (main)

import Array
import Dict
import Set


type Shape
    = Circle Float
    | Rect Int Int
    | None_
    


type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)
    


hashOf : a -> a
hashOf x =
    x


pairs : String -> List ( a, a ) -> String
pairs label ps =
    label ++ " " ++ Debug.toString (List.map (\( x, y ) -> ( x == y, hashOf x == hashOf y )) ps)


lines : List String
lines =
    [ pairs "int" [ ( 1, 1 ), ( 1, 2 ), ( -1, 1 ), ( 0, 0 ), ( 123456789012, 123456789012 ) ]
    , pairs "float" [ ( 0, -0.0 ), ( 1.5, 1.5 ), ( 1.5, 2.5 ), ( 1 / 0, 1 / 0 ), ( 1 / 0, -1 / 0 ) ]
    , pairs "string" [ ( "", "" ), ( "a", "a" ), ( "a", "b" ), ( "héllo", "héllo" ), ( "ab", "ba" ) ]
    , pairs "char" [ ( 'a', 'a' ), ( 'a', 'b' ) ]
    , pairs "bool" [ ( True, True ), ( True, False ) ]
    , pairs "unit" [ ( (), () ) ]
    , pairs "tuple" [ ( ( 1, "a" ), ( 1, "a" ) ), ( ( 1, "a" ), ( 1, "b" ) ) ]
    , pairs "tuplef" [ ( ( 0, -0.0 ), ( 0, 0 ) ), ( ( 1, 2.5 ), ( 1, 2 ) ) ]
    , pairs "list" [ ( [ 1, 2 ], [ 1, 2 ] ), ( [ 1, 2 ], [ 2, 1 ] ), ( [], [] ), ( [ 1 ], [ 1, 1 ] ) ]
    , pairs "record" [ ( { a = 1, b = "x" }, { b = "x", a = 1 } ), ( { a = 1, b = "x" }, { a = 1, b = "y" } ) ]
    , pairs "maybe" [ ( Just 1, Just 1 ), ( Just 1, Nothing ), ( Nothing, Nothing ), ( Just 0, Nothing ) ]
    , pairs "result" [ ( Ok 1, Ok 1 ), ( Ok 1, Err "1" ), ( Err "e", Err "e" ) ]
    , pairs "array" [ ( Array.fromList [ 1, 2 ], Array.fromList [ 1, 2 ] ), ( Array.fromList (List.range 1 50), Array.fromList (List.range 1 50) ), ( Array.fromList [ 1 ], Array.fromList [ 2 ] ) ]
    , pairs "vector" [ ( [ 1, 2 ], [ 1, 2 ] ), ( [ 1, 2 ], [ 1 ] ) ]
    , pairs "dict" [ ( Dict.fromList [ ( 1, "a" ), ( 2, "b" ), ( 3, "c" ) ], Dict.fromList [ ( 3, "c" ), ( 1, "a" ), ( 2, "b" ) ] ), ( Dict.fromList [ ( 1, "a" ) ], Dict.fromList [ ( 1, "b" ) ] ) ]
    , pairs "set" [ ( Set.fromList [ 5, 1, 3, 2, 4 ], Set.fromList [ 1, 2, 3, 4, 5 ] ), ( Set.fromList [ 1 ], Set.fromList [ 1, 2 ] ) ]
    , pairs "shape" [ ( Circle 0, Circle -0.0 ), ( Rect 1 2, Rect 1 2 ), ( Rect 1 2, Rect 2 1 ), ( None_, None_ ), ( None_, Circle 0 ) ]
    , pairs "tree" [ ( Node Leaf "a" Leaf, Node Leaf "a" Leaf ), ( Node Leaf "a" Leaf, Node (Node Leaf "a" Leaf) "a" Leaf ), ( Leaf, Leaf ) ]
    , pairs "nested" [ ( [ Just { s = Circle 1, t = Dict.fromList [ ( "k", [ 1 ] ) ] } ], [ Just { s = Circle 1, t = Dict.fromList [ ( "k", [ 1 ] ) ] } ] ), ( [ Just { s = Circle 1, t = Dict.empty } ], [ Nothing ] ) ]
    , pairs "word64" [ ( ( 2147483648, 0 ), ( 2147483648, 0 ) ), ( ( 2147483648, 0 ), ( 0, 1 ) ) ]
    , pairs "float32" [ ( 0, -0.0 ), ( 0, 1 ) ]
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
