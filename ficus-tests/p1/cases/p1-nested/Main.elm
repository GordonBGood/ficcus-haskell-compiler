module Main exposing (main)

type T r
    = T { r | x : Int }


type N r
    = N { r | v : Int } (Maybe (N r))


inner =
    T { x = 2, z = "a" }


lines : List String
lines =
    [ Debug.toString (T { x = 1, inner = inner })
    , Debug.toString ( T { x = 1, inner = inner } == T { x = 1, inner = T { x = 2, z = "b" } }, T { x = 1, inner = inner } == T { x = 1, inner = inner } )
    , Debug.toString (N { v = 1, s = "a" } (Just (N { v = 2, s = "b" } Nothing)))
    , Debug.toString ( N { v = 1, s = "a" } (Just (N { v = 2, s = "b" } Nothing)) == N { v = 1, s = "a" } (Just (N { v = 2, s = "c" } Nothing)) )
    , Debug.toString (T { x = 0, t = T { x = 1, t = T { x = 2 } } })
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
