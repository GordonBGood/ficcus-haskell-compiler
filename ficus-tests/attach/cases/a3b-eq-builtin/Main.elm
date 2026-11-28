module Main exposing (main)

import Array
import Dict
import Set


type Name
    = Name String
    where
        eq : Name -> Name -> Bool
        eq (Name a) (Name b) =
            String.toLower a == String.toLower b


name : String -> Name
name s =
    Name s

same : a -> a -> Bool
same x y =
    x == y


okName : Name -> Result String Name
okName =
    Ok


names : Int -> List Name
names n =
    List.map (\i -> name ("n" ++ String.fromInt i)) (List.range 1 n)


lines : List String
lines =
    List.map Debug.toString
        [ [ name "a", name "B" ] == [ name "A", name "b" ]
        , [ name "a" ] == [ name "a", name "b" ]
        , [ name "a", name "c" ] == [ name "A", name "b" ]
        , ( name "x", 1 ) == ( name "X", 1 )
        , ( name "x", 1 ) == ( name "X", 2 )
        , ( name "x", name "y", "z" ) == ( name "X", name "Y", "z" )
        , { n = name "q", k = 3 } == { n = name "Q", k = 3 }
        , { n = name "q", k = 3 } == { n = name "R", k = 3 }
        , Just (name "m") == Just (name "M")
        , Just (name "m") == Nothing
        , okName (name "e") == okName (name "E")
        , okName (name "e") == Err "e"
        , Dict.fromList [ ( 1, name "d" ), ( 2, name "e" ) ] == Dict.fromList [ ( 2, name "E" ), ( 1, name "D" ) ]
        , Dict.fromList [ ( 1, name "d" ) ] == Dict.fromList [ ( 1, name "x" ) ]
        , Array.fromList [ name "a", name "b" ] == Array.fromList [ name "A", name "B" ]
        , Array.fromList (names 40) == Array.push (name "N40") (Array.fromList (names 39))
        , Array.fromList (names 40) == Array.fromList (names 41)
        , [ Just ( name "n", 1 ) ] /= [ Just ( name "N", 1 ) ]
        , [ Just ( name "n", 1 ) ] /= [ Just ( name "N", 2 ) ]
        , List.member (name "Z") [ name "y", name "z" ]
        , List.member (Just (name "Z")) [ Nothing, Just (name "z") ]
        , List.member ( name "Z", 1 ) [ ( name "z", 2 ) ]
        , same ( name "g", 2 ) ( name "G", 2 )
        , same [ [ name "g" ] ] [ [ name "G" ] ]
        , [ { a = Just [ ( name "deep", 1 ) ] } ] == [ { a = Just [ ( name "DEEP", 1 ) ] } ]
        , List.filter (\x -> x == ( name "K", [ name "l" ] )) [ ( name "k", [ name "L" ] ), ( name "k", [] ) ] == [ ( name "K", [ name "l" ] ) ]
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
