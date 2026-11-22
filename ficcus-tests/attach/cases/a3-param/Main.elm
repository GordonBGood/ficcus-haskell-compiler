module Main exposing (main)



type V a
    = V (List a)
    where
        append : V a -> V a -> V a
        append (V x) (V y) =
            V (x ++ y)

        compare : V a -> V a -> Order
        compare (V x) (V y) =
            Basics.compare (List.length x) (List.length y)


type S
    = S String
    where
        append : S -> S -> S
        append (S a) (S b) =
            S (a ++ b)

        compare : S -> S -> Order
        compare (S a) (S b) =
            Basics.compare (String.length a) (String.length b)

one : Int
one =
    1

two : Int
two =
    2

-- the elements are typed Int values; literals (`V [ 1 ]`, review finding F7, fixed in A3c) are case a3-f7-literal
compApp : compappend -> compappend -> Bool
compApp a b =
    a ++ b > b

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
                            [ Debug.toString (compApp (S "ab") (S "c"))
                            , Debug.toString (compApp "ab" "c")
                            , Debug.toString (compApp [ 1, 2 ] [ 3 ])
                            , Debug.toString (compApp (V [ one, two ]) (V [ one ]))
                            , Debug.toString (V [ one ] ++ V [ two, one ] < V [ one ])
                            , Debug.toString (List.sort [ V [ one, two ], V [ one ], V [] ] == [ V [], V [ one ], V [ one, two ] ])
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }

