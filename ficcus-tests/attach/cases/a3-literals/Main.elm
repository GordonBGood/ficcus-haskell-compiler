module Main exposing (main)


{-| An integer literal at a type with `fromInt` is `fromInt` of it. Fractions: tenths. -}
type Tenths
    = Tenths Int
    where
        add : Tenths -> Tenths -> Tenths
        add (Tenths a) (Tenths b) =
            Tenths (a + b)

        sub : Tenths -> Tenths -> Tenths
        sub (Tenths a) (Tenths b) =
            Tenths (a - b)

        mul : Tenths -> Tenths -> Tenths
        mul (Tenths a) (Tenths b) =
            Tenths (a * b // 10)

        pow : Tenths -> Tenths -> Tenths
        pow (Tenths a) (Tenths b) =
            Tenths (a ^ (b // 10))

        neg : Tenths -> Tenths
        neg (Tenths a) =
            Tenths (negate a)

        abs : Tenths -> Tenths
        abs (Tenths a) =
            Tenths (Basics.abs a)

        fromInt : Int -> Tenths
        fromInt n =
            Tenths (n * 10)

        compare : Tenths -> Tenths -> Order
        compare (Tenths a) (Tenths b) =
            Basics.compare a b


t : Tenths -> String
t (Tenths n) =
    String.fromInt (n // 10) ++ "." ++ String.fromInt (modBy 10 (Basics.abs n))


five : Tenths
five =
    5


half : Tenths
half =
    Tenths 5


poly : number
poly =
    7


square : number -> number
square x =
    x * x


total : List Tenths -> Tenths
total xs =
    List.foldl (+) 0 xs


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
                            [ "five " ++ t five
                            , "sum " ++ t (five + half + 2)
                            , "neg " ++ t (-3)
                            , "negexpr " ++ t (-five + 1)
                            , "list " ++ String.join " " (List.map t [ 1, 2, 3 ])
                            , "total " ++ t (total [ 1, 2, half ])
                            , "sum2 " ++ t (List.sum [ five, 3 ])
                            , "product " ++ t (List.product [ 2, 3 ])
                            , "poly " ++ t poly ++ " " ++ String.fromInt poly ++ " " ++ String.fromFloat poly
                            , "square " ++ t (square half) ++ " " ++ String.fromInt (square 4) ++ " " ++ String.fromFloat (square 1.5)
                            , "ifelse " ++ t (if five > 3 then 1 else 2)
                            , "abs " ++ t (abs -4)
                            , "int " ++ String.fromInt (1 + 2 * 3)
                            , "float " ++ String.fromFloat (1 + 2.5)
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
