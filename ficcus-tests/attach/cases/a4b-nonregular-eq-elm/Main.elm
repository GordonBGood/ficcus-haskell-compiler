module Main exposing (main)



type Nest a
    = Nil
    | Cons a (Nest (List a))


lines : List String
lines =
    [ Debug.toString (Cons 1 (Cons [ 2 ] Nil) == Cons 1 (Cons [ 2 ] Nil), Cons 1 Nil == Nil) ]


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
