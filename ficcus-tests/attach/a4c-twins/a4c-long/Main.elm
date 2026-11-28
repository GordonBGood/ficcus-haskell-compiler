module Main exposing (main)



type Big
    = Big (List Int) String (List String)
    | Chars (List Char)


big : Big
big =
    Big (List.range -5000 5000)
        (String.repeat 700 "a\"\\\n\t é😀\u{0001}中")
        (List.map (\i -> String.fromInt i ++ "\u{000B}" ++ String.repeat (modBy 7 i) "ü") (List.range 1 1000))


lines : List String
lines =
    [ Debug.toString big
    , Debug.toString (Chars (String.toList (String.repeat 300 "x'\"\\\r😀")))
    , String.fromInt (List.length (String.toList (Debug.toString big)))
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
