module Main exposing (main)


type T r
    = T { r | age : Int }
    where
        derive compare, hash


lines : List String
lines =
    [ Debug.toString ( compare (T { age = 5, name = "zz" }) (T { age = 5, name = "a" }), T.hash (T { age = 5, name = "zz" }) == T.hash (T { age = 5, name = "a" }) ) ]


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
