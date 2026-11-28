module Main exposing (main)



type Money
    = Money Int
    where
        add : Money -> Money -> Money
        add (Money a) (Money b) =
            Money (a + b)


lines : List String
lines =
    [ Debug.toString (compare { f = identity, n = 1 } { f = identity, n = 2 }) ]


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
