module Main exposing (main)



ciHash : Ci -> Int
ciHash (Ci s) =
    String.length s * 1000 + Char.toCode (Maybe.withDefault 'z' (List.head (String.toList (String.toLower s))))


type Ci
    = Ci String
    where
        eq : Ci -> Ci -> Bool
        eq (Ci a) (Ci b) =
            String.toLower a == String.toLower b

        hash : Ci -> Int
        hash =
            ciHash


type Key
    = Key Ci Int
    | Many (List Ci)
    where
        derive hash


hashOf : a -> Int
    where
        a has hash : a -> Int
hashOf x =
    hash x


pairs : String -> List ( a, a ) -> String
    where
        a has hash : a -> Int
pairs label ps =
    label ++ " " ++ Debug.toString (List.map (\( x, y ) -> ( x == y, hashOf x == hashOf y )) ps)


lines : List String
lines =
    [ pairs "key" [ ( Key (Ci "Ab") 1, Key (Ci "aB") 1 ), ( Key (Ci "Ab") 1, Key (Ci "Ab") 2 ), ( Many [ Ci "X", Ci "y" ], Many [ Ci "x", Ci "Y" ] ), ( Many [], Many [ Ci "" ] ) ]
    , pairs "nested" [ ( ( Just (Ci "Q"), 1 ), ( Just (Ci "q"), 1 ) ), ( ( Just (Ci "Q"), 1 ), ( Nothing, 1 ) ) ]
    , Debug.toString ( Key.hash (Key (Ci "A") 0) == Key.hash (Key (Ci "a") 0), Ci.hash (Ci "Abc") )
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
