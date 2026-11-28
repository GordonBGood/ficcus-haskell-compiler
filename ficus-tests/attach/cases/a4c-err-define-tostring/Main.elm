module Main exposing (main)



type Color
    = Red
    where
        derive toString

        toString : Color -> String
        toString _ =
            "r"


lines : List String
lines =
    [ Color.toString Red ]


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
