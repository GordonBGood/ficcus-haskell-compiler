module Main exposing (main)

type T r
    = T { r | x : Int }


getX : T r -> Int
getX (T r) =
    r.x


bump : T r -> T r
bump (T r) =
    T { r | x = r.x + 1 }


lines : List String
lines =
    [ String.fromInt (getX (T { x = 7, w = "w" }) + getX (T { x = 8 }))
    , Debug.toString (bump (T { x = 0, f = 1.5 }))
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
