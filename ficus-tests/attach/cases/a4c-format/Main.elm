module Main exposing (main)

import Array
import Dict
import Set


type alias Person =
    { name : String, age : Int, zeta : Float, aB : Int, ab : Int, m : Int, arr : Int }


type P
    = P Person
    | Q {}
    | E { b : Int, a : ( Int, Float ), c : { z : Int, y : String } }
    where
        derive toString


type Shape
    = Circle Float
    | Rect Float Float
    | Named String Shape
    | Pt { x : Int, y : Int }
    | Unit
    | Many (List Shape) (Maybe Shape) ( Int, Char )
    | Res (Result String (Maybe Int)) (Result (List Int) ())
    | Box (Dict.Dict Int String) (Set.Set Char) (Array.Array Float)
    | Flags Bool Order ()
    | Deep (Maybe (Maybe (Maybe Int))) (List (List Shape))
    where
        derive toString


type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)
    where
        derive toString


type Ext r
    = Ext { r | x : Int }
    where
        derive toString


type Txt
    = Txt String Char
    | Cs (List Char)
    where
        derive toString


bump : Person -> Person
bump p =
    { p | age = p.age + 1 }


floats : List Float
floats =
    [ 1.0, -0.0, 0.1, 1.0e21, 1.0e-7, 123456789012345678, 0 / 0, 1 / 0, -1 / 0, -2.5, 5.0e-324, 1.7976931348623157e308, 100, 1.0e20, 0.000001 ]


shapes : List Shape
shapes =
    List.map Circle floats
        ++ [ Rect -1 2
           , Named "a b" (Circle 0)
           , Named "x" (Named "y" (Rect 1 2))
           , Pt { x = -1, y = 2 }
           , Unit
           , Many [ Unit, Circle -3 ] (Just (Named "" Unit)) ( -9007199254740991, '\'' )
           , Many [] Nothing ( 0, ' ' )
           , Res (Ok (Just -1)) (Err [ -1, 2 ])
           , Res (Err "e r") (Ok ())
           , Box (Dict.fromList [ ( 2, "b" ), ( 1, "a" ) ]) (Set.fromList [ 'z', 'a' ]) (Array.fromList [ 1.5, -0 ])
           , Box Dict.empty Set.empty Array.empty
           , Flags True LT ()
           , Flags False GT ()
           , Deep (Just (Just Nothing)) [ [ Unit ], [] ]
           , Deep (Just (Just (Just -7))) []
           ]


txts : List Txt
txts =
    [ Txt "a\"b\\c\nd\te'f\r\u{000B}\u{0000}é😀\u{007F}\u{0001}" '"'
    , Txt "" '\\'
    , Txt "hello world" '\n'
    , Cs [ 'a', '\'', '"', '\\', '\n', '\t', '\u{0000}', '\u{000D}', '\u{000B}', 'é', '😀', '\u{007F}', '\u{0001}', '\u{001F}', '中' ]
    ]


lines : List String
lines =
    [ P.toString (P { name = "Bo", age = 3, zeta = 1.5, aB = 1, ab = 2, m = 4, arr = 5 })
    , P.toString (P (Person "Al" -4 -0.5 7 8 9 10))
    , P.toString (P (bump (Person "Al" 4 -0.5 7 8 9 10)))
    , P.toString (Q {})
    , P.toString (E { b = 1, a = ( -1, 0 / 0 ), c = { z = 1, y = "s t" } })
    , Tree.toString (Node (Node Leaf 1 Leaf) 2 Leaf)
    , Tree.toString (Node Leaf -2 (Node Leaf 3 Leaf))
    , Tree.toString (Node Leaf "s t" Leaf)
    , Tree.toString (Node Leaf -1.5 (Node Leaf (0 / 0) Leaf))
    , Tree.toString (Node Leaf (Just -1) Leaf)
    , Tree.toString (Node Leaf (Node Leaf 'c' Leaf) Leaf)
    , Tree.toString (Node Leaf { a = -1, b = [ "x" ] } Leaf)
    , Tree.toString (Node Leaf ( 1, "a", 'c' ) Leaf)
    , Tree.toString (Node Leaf Unit (Node Leaf (Circle -1) Leaf))
    , Tree.toString (Node Leaf [ Ok 1, Err "e" ] Leaf)
    , Tree.toString (Leaf |> always (Node Leaf () Leaf))
    , Ext.toString (Ext { x = 1, y = 2 })
    , Ext.toString (Ext { x = -1, w = "s", aa = [ 1.5 ] })
    , Ext.toString (Ext { x = 3 })
    ]
        ++ List.map Shape.toString shapes
        ++ List.map Txt.toString txts
        ++ [ Debug.toString (List.map (\s -> ( s, Unit )) shapes) ]


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
