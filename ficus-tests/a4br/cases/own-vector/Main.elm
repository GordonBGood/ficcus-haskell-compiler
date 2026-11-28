module Main exposing (main)

import Vector exposing (Vector)


type Color
    = Red
    | Blue
    where
        derive compare


lines : List String
lines =
    [ Debug.toString (compare (Vector.fromList [ 1, 2 ]) (Vector.fromList [ 1 ])) ]


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
