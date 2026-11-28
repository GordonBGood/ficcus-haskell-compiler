module Main exposing (main)



type Name
    = Name String
    where
        eq : Name -> Name -> Bool
        eq (Name a) (Name b) =
            String.toLower a == String.toLower b


name : String -> Name
name s =
    Name s

type Shape
    = Circle Name Int
    | Pair ( Name, Name )
    | Rec { n : Name, k : Int }
    | Empty


type Tree
    = Leaf
    | Node Tree Name Tree


type A
    = A (List B)
    | AEnd


type B
    = B Name A


type Box a
    = Box a (Maybe (Box a))


lines : List String
lines =
    List.map Debug.toString
        [ Circle (name "c") 1 == Circle (name "C") 1
        , Circle (name "c") 1 == Circle (name "C") 2
        , Pair ( name "a", name "b" ) == Pair ( name "A", name "B" )
        , Rec { n = name "r", k = 1 } == Rec { n = name "R", k = 1 }
        , Empty == Circle (name "c") 1
        , Empty == Empty
        , Node Leaf (name "t") (Node Leaf (name "u") Leaf) == Node Leaf (name "T") (Node Leaf (name "U") Leaf)
        , Node Leaf (name "t") Leaf == Node Leaf (name "T") (Node Leaf (name "U") Leaf)
        , A [ B (name "m") AEnd, B (name "n") (A []) ] == A [ B (name "M") AEnd, B (name "N") (A []) ]
        , A [ B (name "m") AEnd ] == A [ B (name "m") (A []) ]
        , Box (name "x") (Just (Box (name "y") Nothing)) == Box (name "X") (Just (Box (name "Y") Nothing))
        , Box ( name "x", 1 ) Nothing == Box ( name "X", 1 ) Nothing
        , Box 1 Nothing == Box 1 (Just (Box 1 Nothing))
        , [ Node Leaf (name "a") Leaf ] == [ Node Leaf (name "A") Leaf ]
        , Just (Pair ( name "p", name "q" )) /= Just (Pair ( name "P", name "Q" ))
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
