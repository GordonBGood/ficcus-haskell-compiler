module Main exposing (main)



type Nest a
    = Nil
    | Cons a (Nest (List a))


type Ci
    = Ci String
    where
        eq : Ci -> Ci -> Bool
        eq (Ci a) (Ci b) =
            String.toLower a == String.toLower b


lines : List String
lines =
    [ Debug.toString (Cons (Ci "a") Nil == Nil, Cons (Ci "b") Nil == Nil) ]


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
