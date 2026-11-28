module Main exposing (main)



type Inner
    = Inner Int


type Outer
    = Outer (List Inner)
    where
        derive compare


lines : List String
lines =
    [ "x" ]


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
