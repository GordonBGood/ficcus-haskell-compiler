module Main exposing (main)



type Id
    = Id Int
    where
        derive hash

        hash : Id -> Int
        hash (Id n) =
            n


lines : List String
lines =
    [ "x" ]


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
