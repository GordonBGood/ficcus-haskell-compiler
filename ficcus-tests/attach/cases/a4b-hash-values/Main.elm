module Main exposing (main)



type Color
    = Red
    | Green
    | Blue
    where
        derive hash


type Shape
    = Circle Int
    | Dot
    where
        derive hash


hashOf : a -> Int
    where
        a has hash : a -> Int
hashOf x =
    hash x


nothing : Maybe Int
nothing =
    Nothing


ok2 : Result String Int
ok2 =
    Ok 2


errE : Result String Int
errE =
    Err "e"


lines : List String
lines =
    List.map String.fromInt
        [ hashOf 0, hashOf 1, hashOf -1, hashOf 123456789, hashOf 'a', hashOf True, hashOf False, hashOf ()
        , hashOf "", hashOf "a", hashOf "hello, world"
        , hashOf ( 1, 2 ), hashOf ( 1, "x", 'c' ), hashOf [ 1, 2, 3 ], hashOf { a = 1, b = "x" }
        , Color.hash Red, Color.hash Blue, Shape.hash Dot, Shape.hash (Circle 7)
        , hashOf (Just 1), hashOf nothing, hashOf ok2, hashOf errE
        , hashOf [ Just Green ]
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
