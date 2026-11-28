module Main exposing (main)



recs : List { x : Int, y : String }
recs =
    [ { x = 2, y = "b" }, { x = 1, y = "z" }, { x = 2, y = "a" }, { x = 0, y = "q" } ]


key : { x : Int, y : String } -> ( Int, String )
key r =
    ( r.x, r.y )


lines : List String
lines =
    [ Debug.toString (List.sortWith (\a b -> if a.x >= 0 then compare (key a) (key b) else EQ) recs)
    , Debug.toString (List.map (\r -> r == { x = 2, y = "a" }) recs)
    , Debug.toString (List.map (\r -> compare (key r) ( 2, "b" )) recs)
    , Debug.toString (List.map (\r -> compare (key r) ( 1, "z" )) recs)
    ]


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
