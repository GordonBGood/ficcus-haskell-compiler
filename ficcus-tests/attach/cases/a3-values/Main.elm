module Main exposing (main)



type Name
    = Name String
    where
        eq : Name -> Name -> Bool
        eq (Name a) (Name b) =
            String.toLower a == String.toLower b


type Ver
    = Ver Int
    where
        compare : Ver -> Ver -> Order
        compare (Ver a) (Ver b) =
            Basics.compare b a


type alias Row =
    { k : Ver, n : Int }

apply : (a -> a -> Bool) -> a -> a -> Bool
apply f x y =
    f x y

logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        logAll
                            [ Debug.toString (apply (==) (Name "a") (Name "A"))
                            , Debug.toString (apply (/=) (Name "a") (Name "A"))
                            , Debug.toString (List.map2 compare [ Ver 1, Ver 2 ] [ Ver 2, Ver 2 ])
                            , Debug.toString (List.map2 (<) [ Ver 1 ] [ Ver 2 ])
                            , Debug.toString (List.map .n (List.sortBy .k [ { k = Ver 1, n = 1 }, { k = Ver 3, n = 3 }, { k = Ver 2, n = 2 } ]))
                            , Debug.toString (List.map .n (List.sortWith (\a b -> compare a.k b.k) [ { k = Ver 1, n = 1 }, { k = Ver 3, n = 3 } ]))
                            , Debug.toString (List.member (Name "X") [ Name "x" ])
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }

