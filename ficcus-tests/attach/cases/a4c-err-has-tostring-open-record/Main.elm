module Main exposing (main)



showIt : a -> String
    where
        a has toString : a -> String
showIt x =
    toString x


f : { r | x : Int } -> String
f r =
    showIt r


lines : List String
lines =
    [ f { x = 1 } ]


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
