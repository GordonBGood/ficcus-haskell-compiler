module Main exposing (main)



type alias Ci =
    String


ciHash : Ci -> Int
ciHash s =
    String.length s * 1000 + Char.toCode (Maybe.withDefault 'z' (List.head (String.toList (String.toLower s))))


type Key
    = Key Ci Int
    | Many (List Ci)


hashOf : a -> a
hashOf x =
    x


pairs : String -> List ( a, a ) -> String
pairs label ps =
    label ++ " " ++ Debug.toString (List.map (\( x, y ) -> ( x == y, hashOf x == hashOf y )) ps)


lines : List String
lines =
    [ pairs "key" [ ( Key "ab" 1, Key "ab" 1 ), ( Key "ab" 1, Key "ab" 2 ), ( Many [ "x", "y" ], Many [ "x", "y" ] ), ( Many [], Many [ "" ] ) ]
    , pairs "nested" [ ( ( Just "q", 1 ), ( Just "q", 1 ) ), ( ( Just "q", 1 ), ( Nothing, 1 ) ) ]
    , Debug.toString ( Key "a" 0 == Key "a" 0, ciHash "Abc" )
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
