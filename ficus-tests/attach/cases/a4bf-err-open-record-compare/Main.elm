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


hashOf : a -> Int
    where
        a has hash : a -> Int
hashOf x =
    hash x


cmpRec : { r | x : Int } -> { r | x : Int } -> Order
cmpRec a b =
    cmpG a b


lines : List String
lines =
    [ Debug.toString (cmpRec { x = 1, f = \n -> n + 1 } { x = 1, f = \n -> n }) ]


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
