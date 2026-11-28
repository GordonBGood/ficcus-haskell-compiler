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


cmpRec a b =
    if a.x > 0 then cmpG a b else EQ


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
