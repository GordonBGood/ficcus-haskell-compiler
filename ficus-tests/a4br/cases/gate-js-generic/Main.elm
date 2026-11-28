module Main exposing (main)

import Lib


type Color
    = Red
    where
        derive hash


lines : List String
lines =
    [ Debug.toString (Lib.sortAny [ { a = 2 }, { a = 1 } ]) ]


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
