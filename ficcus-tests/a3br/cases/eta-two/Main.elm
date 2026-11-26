module Main exposing (main)


type Tag a
    = Tag String a
    where
        eq : Tag a -> Tag a -> Bool
        eq =
            eqBy tagKey

        compare : Tag a -> Tag a -> Order
        compare (Tag x _) =
            \(Tag y _) -> Basics.compare (String.length x) (String.length y)


tagKey : Tag a -> String
tagKey (Tag s _) =
    String.toLower s


eqBy : (t -> String) -> t -> t -> Bool
eqBy f =
    \x y -> f x == f y


lines : List String
lines =
    [ Debug.toString ([ Tag "a" 1 ] == [ Tag "A" 2 ])
    , Debug.toString ([ Tag "a" "x" ] == [ Tag "A" "y" ])
    , Debug.toString (Just (Tag "b" [ 1 ]) == Just (Tag "c" [ 1 ]))
    , Debug.toString (compare [ Tag "aa" 1 ] [ Tag "b" 2 ])
    , Debug.toString (compare ( Tag "aa" "s", 0 ) ( Tag "bb" "t", 0 ))
    , Debug.toString (compare ( Tag "a" [ 'c' ], 0 ) ( Tag "bb" [], 0 ))
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
