module Main exposing (main)


type alias Ci =
    String


sameRec : { r | k : Ci } -> { r | k : Ci } -> Bool
sameRec a b =
    a == b


sameKey : { r | k : Ci } -> { r | k : Ci } -> Bool
sameKey a b =
    [ a.k ] == [ b.k ]


lines : List String
lines =
    [ Debug.toString (sameRec { k = "a", n = 1 } { k = "a", n = 1 })
    , Debug.toString (sameKey { k = "a", n = 1 } { k = "a", n = 2 })
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
