module Main exposing (main)

import Array as Vector


type Name
    = Name String


name : String -> Name
name s =
    Name (String.toLower s)

lines : List String
lines =
    List.map Debug.toString
        [ Vector.fromList [ name "a", name "b" ] == Vector.fromList [ name "A", name "B" ]
        , Vector.fromList [ name "a" ] == Vector.fromList [ name "A", name "B" ]
        , Vector.fromList [ ( name "a", 1 ) ] == Vector.fromList [ ( name "A", 1 ) ]
        , [ Vector.fromList [ Just (name "v") ] ] == [ Vector.fromList [ Just (name "V") ] ]
        , Vector.fromList [ name "a" ] /= Vector.fromList [ name "b" ]
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
