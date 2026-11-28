module Main exposing (main)


type Color
    = Red
    | Green
    where
        derive compare


cmpG : a -> a -> Order
    where
        a has compare : a -> a -> Order
cmpG x y =
    compare x y


cmpRec : { r | x : Int } -> { r | x : Int } -> Order
cmpRec a b =
    cmpG a b


lines : List String
lines =
    [ Debug.toString (cmpRec { x = 1, a = 5 } { x = 1, a = 3 }, cmpRec { x = 1, z = 5 } { x = 2, z = 3 }) ]


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
