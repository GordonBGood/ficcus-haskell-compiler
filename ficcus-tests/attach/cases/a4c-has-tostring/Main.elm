module Main exposing (main)

import Array
import Dict
import Set


type Color
    = Red
    | Green
    | Blue
    where
        derive toString


type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)
    where
        derive toString


type Name
    = Name String
    where
        toString : Name -> String
        toString (Name s) =
            s


type Wrap
    = Wrap Name (List Name)
    where
        derive toString


showIt : a -> String
    where
        a has toString : a -> String
showIt x =
    toString x


results : ( Result String Int, Result Char Int )
results =
    ( Ok 1, Err 'e' )


showAll : List a -> List String
    where
        a has toString : a -> String
showAll xs =
    List.map toString xs


lines : List String
lines =
    [ showIt 1
    , showIt -9007199254740991
    , showIt 1.5
    , showIt (0 / 0)
    , showIt "s \"q\"\n"
    , showIt 'c'
    , showIt [ Just 1.5, Nothing ]
    , showIt { b = 1, a = "x" }
    , showIt ( True, LT )
    , showIt ( (), 1 )
    , showIt results
    , showIt (Dict.fromList [ ( 1, Red ) ])
    , showIt (Set.fromList [ "b", "a" ])
    , showIt (Array.fromList [ Red, Blue ])
    , showIt Red
    , showIt (Node Leaf Red Leaf)
    , showIt { c = Red, t = Node Leaf ( Blue, [ Green ] ) Leaf }
    , showIt (Just (Node Leaf (Just Red) Leaf))
    , showIt (Wrap (Name "bob") [ Name "al", Name "" ])
    , showIt (Name "bob")
    , Wrap.toString (Wrap (Name "x y") [])
    , String.join "|" (showAll [ Red, Green, Blue ])
    , String.join "|" (showAll [ [ 1 ], [] ])
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
