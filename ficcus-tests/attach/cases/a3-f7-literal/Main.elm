module Main exposing (main)

import Dict


type V a
    = V (List a)
    where
        append : V a -> V a -> V a
        append (V x) (V y) =
            V (x ++ y)

        compare : V a -> V a -> Order
        compare (V x) (V y) =
            Basics.compare (List.length x) (List.length y)


smallest : a -> a -> a
    where
        a has compare : a -> a -> Order
smallest x y =
    case compare x y of
        GT ->
            y

        _ ->
            x


typed : Order
typed =
    compare (V [ 1 ]) (V [ 2, 3 ])


untyped =
    compare (V [ 1, 2 ]) (V [ 3 ])


floats : Order
floats =
    compare (V [ 1.5 ]) (V [ 2, 3 ])


record : { v : V number, n : Int }
record =
    { v = V [ 1, 2, 3 ], n = 0 }


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
                            [ Debug.toString typed
                            , Debug.toString untyped
                            , Debug.toString floats
                            , Debug.toString (V [ 1 ] < V [ 1, 2 ])
                            , Debug.toString (max (V [ 1 ]) (V [ 1, 2 ]))
                            , Debug.toString (V [ 1 ] ++ V [ 2, 3 ])
                            , Debug.toString (compare (V [ 1 ] ++ V [ 2 ]) (V [ 3 ]))
                            , Debug.toString (List.sort [ V [ 1, 2 ], V [], V [ 3 ] ])
                            , Debug.toString (List.sortBy .v [ { v = V [ 1, 2 ] }, { v = V [ 3 ] } ])
                            , Debug.toString (List.sortBy .v [ record, { v = V [ 4 ], n = 1 } ])
                            , Debug.toString (compare record.v (V [ 1 ]))
                            , Debug.toString (Dict.toList (Dict.fromList [ ( V [ 1, 2 ], "two" ), ( V [ 3 ], "one" ) ]))
                            , Debug.toString (Dict.get (V [ 9 ]) (Dict.fromList [ ( V [ 1 ], "one" ) ]))
                            , Debug.toString (smallest (V [ 1, 2 ]) (V [ 3 ]))
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
