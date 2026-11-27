module Main exposing (main)



type A a
    = A a (B a)
    | AN
    where
        derive compare


type B a
    = B (C (Maybe a))


type C a
    = C (A a)
    | CN


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
