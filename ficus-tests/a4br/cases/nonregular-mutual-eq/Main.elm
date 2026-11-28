module Main exposing (main)


type A a
    = A a (B (List a))
    | AN


type B a
    = B (A a)
    | BN


lines : List String
lines =
    [ Debug.toString (A 1 BN == A 1 (B AN)) ]


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
