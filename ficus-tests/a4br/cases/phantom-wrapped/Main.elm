module Main exposing (main)


type Id a
    = Id Int
    where
        derive compare


type W a
    = W (Id a)
    where
        derive compare


fnW : Int -> W (Int -> Int)
fnW n =
    W (Id n)


lines : List String
lines =
    [ Debug.toString (fnW 1 < fnW 2) ]


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
