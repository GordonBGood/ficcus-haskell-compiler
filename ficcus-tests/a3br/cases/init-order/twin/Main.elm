module Main exposing (main)

-- twin: Part n s as its key n (the members compare partKey only)


type alias Part =
    Int


part : Int -> String -> Part
part n _ =
    n


table : List ( Part, Int )
table =
    List.sort [ ( part 3 "c", 0 ), ( part 1 "a", 0 ) ]


early : Bool
early =
    [ ( part 1 "x", 0 ) ] == [ ( part 1 "y", 0 ) ]


lines : List String
lines =
    [ Debug.toString early
    , Debug.toString (List.map (\( n, _ ) -> n) table)
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
