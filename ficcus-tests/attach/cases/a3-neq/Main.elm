module Main exposing (main)


{-| A name that is compared without regard to case: its own `eq`. -}
type Name
    = Name String
    where
        eq : Name -> Name -> Bool
        eq (Name a) (Name b) =
            String.toLower a == String.toLower b


{-| No `eq`: `==` is the automatic structural equality, as in Elm. -}
type Color
    = Red
    | Green
    | Mixed Int Int


type Pair a
    = Pair a a
    where
        eq : Pair a -> Pair a -> Bool
        eq (Pair a b) (Pair c d) =
            -- unordered: the pair (1, 2) equals (2, 1)
            (a == c && b == d) || (a == d && b == c)


same : a -> a -> Bool
same x y =
    x == y


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
                            [ "eq " ++ Debug.toString (Name "Ann" == Name "ANN")
                            , "ne " ++ Debug.toString (Name "Ann" /= Name "ANN")
                            , "ne2 " ++ Debug.toString (Name "Ann" /= Name "Bob")
                            , "eq2 " ++ Debug.toString (Name "Ann" == Name "Bob")
                            , "member " ++ Debug.toString (List.member (Name "bob") [ Name "Ann", Name "BOB" ])
                            , "filter " ++ Debug.toString (List.length (List.filter (\n -> n /= Name "ann") [ Name "Ann", Name "Bob", Name "ANN" ]))
                            , "same " ++ Debug.toString (same (Name "x") (Name "X"))
                            , "color " ++ Debug.toString (Mixed 1 2 == Mixed 1 2)
                            , "color2 " ++ Debug.toString (Red /= Green)
                            , "maybe " ++ Debug.toString (Just 3 == Just 3)
                            , "pair " ++ Debug.toString (Pair 1 2 == Pair 2 1)
                            , "pairne " ++ Debug.toString (Pair 1 2 /= Pair 1 3)
                            , "pairs " ++ Debug.toString (Pair "a" "b" == Pair "b" "a")
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
