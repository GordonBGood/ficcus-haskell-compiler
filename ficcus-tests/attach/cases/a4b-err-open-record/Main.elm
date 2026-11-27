module Main exposing (main)



type Money
    = Money Int
    where
        add : Money -> Money -> Money
        add (Money a) (Money b) =
            Money (a + b)


cmpA : { r | a : Int } -> { r | a : Int } -> Order
cmpA x y =
    compare x y


lines : List String
lines =
    [ Debug.toString (cmpA { a = 1 } { a = 2 }) ]


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
