module Main exposing (main)


{-| A type with `div`, `idiv`, `mod` and `rem` is in sight, so `/`, `//`, `modBy` and `remainderBy` are typed by the member of the type
they are used at. Every use at Float and Int must still mean what it means in Elm: an open type becomes Float for `/` and Int for the others. -}
type Ratio
    = Ratio Int Int
    where
        div : Ratio -> Ratio -> Ratio
        div (Ratio a b) (Ratio c d) =
            Ratio (a * d) (b * c)

        idiv : Ratio -> Ratio -> Ratio
        idiv (Ratio a b) (Ratio c d) =
            Ratio ((a * d) // (b * c)) 1

        mod : Ratio -> Ratio -> Ratio
        mod (Ratio _ _) x =
            x

        rem : Ratio -> Ratio -> Ratio
        rem (Ratio _ _) x =
            x


avg a b =
    (a + b) / 2


half x =
    x / 2


quot =
    (//)


twoThirds =
    2 / 3


halfInt : Int -> Int
halfInt n =
    n // 2


digits : Int -> Int
digits n =
    modBy 10 n + remainderBy 10 (n // 10)


ratio : Ratio -> String
ratio (Ratio a b) =
    String.fromInt a ++ "/" ++ String.fromInt b


logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    local x =
                        x / 4

                    _ =
                        logAll
                            [ "avg " ++ String.fromFloat (avg 1 2)
                            , "half " ++ String.fromFloat (half 5)
                            , "quot " ++ String.fromInt (quot 17 5)
                            , "twoThirds " ++ String.fromFloat twoThirds
                            , "halfInt " ++ String.fromInt (halfInt 9)
                            , "digits " ++ String.fromInt (digits 47)
                            , "local " ++ String.fromFloat (local 3)
                            , "ratio " ++ ratio (Ratio 1 2 / Ratio 3 4)
                            , "ratioIdiv " ++ ratio (Ratio 7 1 // Ratio 2 1)
                            , "ratioMod " ++ ratio (modBy (Ratio 1 1) (Ratio 5 3))
                            , "mixed " ++ String.fromFloat (toFloat (7 // 2) / 2)
                            , "map " ++ Debug.toString (List.map (\n -> n // 2) [ 4, 5, 6 ])
                            , "floatmap " ++ Debug.toString (List.map (\x -> x / 2) [ 4, 5, 6 ])
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
