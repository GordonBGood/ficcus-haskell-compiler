module Main exposing (main)


type Color
    = Red
    | Green
    where
        derive compare


sortRecs : List { r | x : Int } -> List { r | x : Int }
sortRecs rs =
    List.sortWith compare rs


lines : List String
lines =
    [ Debug.toString (List.length (sortRecs [ { x = 1, f = \n -> n + 1 }, { x = 1, f = \n -> n } ])) ]


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
