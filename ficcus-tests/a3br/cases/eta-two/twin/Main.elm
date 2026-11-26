module Main exposing (main)

-- twin: eq is on the lowered string, compare on its length


lines : List String
lines =
    [ Debug.toString ([ String.toLower "a" ] == [ String.toLower "A" ])
    , Debug.toString ([ String.toLower "a" ] == [ String.toLower "A" ])
    , Debug.toString (Just (String.toLower "b") == Just (String.toLower "c"))
    , Debug.toString (compare [ String.length "aa" ] [ String.length "b" ])
    , Debug.toString (compare ( String.length "aa", 0 ) ( String.length "bb", 0 ))
    , Debug.toString (compare ( String.length "a", 0 ) ( String.length "bb", 0 ))
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
