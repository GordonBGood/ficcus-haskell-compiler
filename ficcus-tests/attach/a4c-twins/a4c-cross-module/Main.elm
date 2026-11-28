module Main exposing (main)

import Shapes exposing (Shape(..))


type Local
    = Local Shape (List Shapes.Secret)


lines : List String
lines =
    [ Debug.toString (Circle 1.5)
    , Debug.toString Dot
    , Debug.toString (Shapes.secret 3)
    , Debug.toString (Local Dot [ Shapes.secret -1 ])
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
