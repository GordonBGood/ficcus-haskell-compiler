module Main exposing (main)

type T r
    = T { r | x : Int }
    where
        derive compare, hash


lines : List String
lines =
    [ Debug.toString (T { x = 1, f = \n -> n } < T { x = 1, f = \n -> n + 1 }) ]


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
