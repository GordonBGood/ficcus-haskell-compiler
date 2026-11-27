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


cmpC : { x : Int, y : String } -> { x : Int, y : String } -> Order
cmpC a b =
    cmpG a b


recs : List { x : Int, y : String }
recs =
    [ { x = 2, y = "b" }, { x = 1, y = "z" }, { x = 2, y = "a" }, { x = 0, y = "q" } ]


lines : List String
lines =
    let
        f a b =
            cmpG a b
    in
    [ Debug.toString (List.sortWith (\a b -> if a.x >= 0 then cmpG a b else EQ) recs)
    , Debug.toString (List.map (\r -> hashOf r == hashOf { x = 2, y = "a" }) recs)
    , Debug.toString (List.map (\r -> f r { y = "b", x = 2 }) recs)
    , Debug.toString (List.map (\r -> cmpC r { x = 1, y = "z" }) recs)
    ]


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
