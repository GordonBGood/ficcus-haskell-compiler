module Main exposing (main)



color : Int -> Int
color i =
    i


rank : Int -> Int
rank c =
    c


seq : List Int
seq =
    List.map (\i -> modBy 3 (i * 7 + i // 5)) (List.range 0 99)


lines : List String
lines =
    [ Debug.toString (List.map rank (List.sort (List.map color seq)))
    , Debug.toString (List.map Tuple.second (List.sortBy Tuple.first (List.indexedMap (\i k -> ( color k, i )) seq)))
    , Debug.toString (List.map Tuple.second (List.sortWith (\( a, _ ) ( b, _ ) -> compare a b) (List.indexedMap (\i k -> ( color k, i )) seq)))
    , Debug.toString (List.map (\( c, i ) -> rank c * 1000 + i) (List.sort (List.indexedMap (\i k -> ( color k, modBy 4 i )) seq)))
    , Debug.toString (List.map rank (List.sort (List.map color seq)))
    , Debug.toString (List.map (\( c, s ) -> String.fromInt (rank c) ++ s) (List.sortWith (\( c1, s1 ) ( c2, s2 ) -> case compare c1 c2 of
                                                                                                                EQ -> compare (String.toLower s1) (String.toLower s2)
                                                                                                                o -> o) [ ( 2, "b" ), ( 0, "B" ), ( 0, "a" ), ( 2, "A" ) ]))
    , Debug.toString (List.map (\l -> List.head l) (List.sort [ [ 2 ], [], [ 0 ], [] ]))
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
