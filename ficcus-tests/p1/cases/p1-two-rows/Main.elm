module Main exposing (main)

type T r
    = T { r | x : Int }


showT : T r -> String
showT t =
    Debug.toString t


same : T r -> T r -> Bool
same a b =
    a == b


lines : List String
lines =
    [ showT (T { x = 1, y = 2 })
    , showT (T { x = 1, name = "n" })
    , showT (T { x = 1 })
    , Debug.toString ( same (T { x = 1, y = 2 }) (T { x = 1, y = 3 }), same (T { x = 1, name = "n" }) (T { x = 1, name = "n" }) )
    , Debug.toString ( same (T { x = 1, name = "n" }) (T { x = 1, name = "m" }), same (T { x = 1 }) (T { x = 1 }) )
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
