module Main exposing (main)


type Color
    = Red
    where
        derive hash


h : a -> z
    where
        a has hash : a -> z
h x =
    hash x


hs : a -> String
    where
        a has hash : a -> String
hs x =
    hash x


lines : List String
lines =
    [ Debug.toString (h 5 + 1), hs 5 ]


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
