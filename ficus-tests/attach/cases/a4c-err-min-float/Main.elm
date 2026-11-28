module Main exposing (main)



low : a -> a
    where
        a has minValue : a
low _ =
    minValue


lines : List String
lines =
    [ Debug.toString (low 1.5) ]


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
