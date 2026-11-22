module Main exposing (main)

import Lib

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
                            [ Debug.toString (Lib.remainderBy (Money 3) (Money 10))
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }

