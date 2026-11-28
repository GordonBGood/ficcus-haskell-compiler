module Main exposing (main)

type T r
    = T { r | x : Int }


bump : T { name : String } -> T { name : String }
bump (T r) =
    T { r | x = r.x + 1 }


bumpF : T { f : Float } -> T { f : Float }
bumpF (T r) =
    T { r | x = r.x + 1, f = r.f * 2 }


rename : T { name : String } -> T { name : String }
rename (T r) =
    T { r | name = r.name ++ "!" }


a =
    T { x = 1, name = "a" }


lines : List String
lines =
    [ Debug.toString (bump a)
    , Debug.toString (rename (bump a))
    , Debug.toString ( bump a == T { x = 2, name = "a" }, rename a == a )
    , Debug.toString (bumpF (bumpF (T { x = 0, f = 1.5 })))
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
