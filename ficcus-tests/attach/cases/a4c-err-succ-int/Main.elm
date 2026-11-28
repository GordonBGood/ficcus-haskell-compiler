module Main exposing (main)



next : a -> Maybe a
    where
        a has succ : a -> Maybe a
next x =
    succ x


lines : List String
lines =
    [ Debug.toString (next one) ]


one : Int
one =
    1


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
