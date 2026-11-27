module Main exposing (main)



type alias Named r =
    { r | name : String }


type T r
    = T Int (List (Named r))
    where
        derive hash


lines : List String
lines =
    [ Debug.toString (T.hash (T 1 [ { name = "a", age = 3 } ])) ]


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
