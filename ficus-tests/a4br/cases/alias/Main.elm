module Main exposing (main)

import Dict


type Color
    = Red
    | Green
    | Blue
    where
        derive compare, hash


type alias P =
    { name : String, c : Color }


type alias K a =
    Maybe ( a, Color )


ps : List P
ps =
    [ { name = "b", c = Red }, { name = "a", c = Blue }, { name = "a", c = Red } ]


ks : List (K Int)
ks =
    [ Just ( 2, Red ), Nothing, Just ( 1, Blue ), Just ( 1, Red ) ]


lines : List String
lines =
    [ Debug.toString (List.sort ps)
    , Debug.toString (Dict.keys (Dict.fromList (List.map (\k -> ( k, () )) ks)))
    , Debug.toString (List.sortBy (\p -> { c = p.c, n = p.name }) ps)
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
