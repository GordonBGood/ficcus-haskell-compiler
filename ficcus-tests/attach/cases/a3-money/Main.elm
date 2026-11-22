module Main exposing (main)

import Dict
import Set


{-| Money in cents. Every well known member, so every operator works on it. Rounding rules are not the point. -}
type Money
    = Money Int
    where
        add : Money -> Money -> Money
        add (Money a) (Money b) =
            Money (a + b)

        sub : Money -> Money -> Money
        sub (Money a) (Money b) =
            Money (a - b)

        mul : Money -> Money -> Money
        mul (Money a) (Money b) =
            Money (a * b // 100)

        pow : Money -> Money -> Money
        pow (Money a) (Money b) =
            Money (a ^ (b // 100))

        neg : Money -> Money
        neg (Money a) =
            Money (negate a)

        abs : Money -> Money
        abs (Money a) =
            Money (Basics.abs a)

        fromInt : Int -> Money
        fromInt n =
            Money (n * 100)

        compare : Money -> Money -> Order
        compare (Money a) (Money b) =
            Basics.compare a b

        eq : Money -> Money -> Bool
        eq (Money a) (Money b) =
            a == b

        div : Money -> Money -> Money
        div (Money a) (Money b) =
            Money (a * 100 // b)

        idiv : Money -> Money -> Money
        idiv (Money a) (Money b) =
            Money ((a // b) * 100)

        mod : Money -> Money -> Money
        mod (Money m) (Money x) =
            Money (modBy m x)

        rem : Money -> Money -> Money
        rem (Money m) (Money x) =
            Money (remainderBy m x)

        append : Money -> Money -> Money
        append (Money a) (Money b) =
            Money (a * 100000 + b)


show : Money -> String
show (Money n) =
    "$" ++ String.fromInt n


logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items


double : number -> number
double x =
    x + x


biggest : comparable -> comparable -> comparable
biggest a b =
    if a > b then a else b


glue : appendable -> appendable -> appendable
glue a b =
    a ++ b


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    a = Money 700
                    b = Money 250
                    _ =
                        logAll
                            [ "add " ++ show (a + b)
                            , "sub " ++ show (a - b)
                            , "mul " ++ show (a * b)
                            , "pow " ++ show (Money 300 ^ Money 200)
                            , "neg " ++ show (-a)
                            , "negate " ++ show (negate b)
                            , "abs " ++ show (abs (b - a))
                            , "div " ++ show (a / b)
                            , "idiv " ++ show (a // b)
                            , "modBy " ++ show (modBy (Money 5) (Money 13))
                            , "remainderBy " ++ show (remainderBy (Money 5) (Money 13))
                            , "append " ++ show (Money 1 ++ Money 2)
                            , "lt " ++ Debug.toString (a < b)
                            , "le " ++ Debug.toString (a <= a)
                            , "gt " ++ Debug.toString (a > b)
                            , "ge " ++ Debug.toString (b >= a)
                            , "compare " ++ Debug.toString (compare a b)
                            , "max " ++ show (max a b)
                            , "min " ++ show (min a b)
                            , "clamp " ++ show (clamp (Money 0) (Money 300) a)
                            , "eq " ++ Debug.toString (a == Money 700)
                            , "ne " ++ Debug.toString (a /= Money 700)
                            , "double " ++ show (double a)
                            , "biggest " ++ show (biggest a b)
                            , "glue " ++ show (glue a b)
                            , "sort " ++ String.join " " (List.map show (List.sort [ Money 3, Money 1, Money 2 ]))
                            , "dict " ++ String.join " " (List.map (\( k, v ) -> show k ++ "=" ++ v) (Dict.toList (Dict.fromList [ ( Money 2, "two" ), ( Money 1, "one" ) ])))
                            , "set " ++ String.join " " (List.map show (Set.toList (Set.fromList [ Money 5, Money 4, Money 5 ])))
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
