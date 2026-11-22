module Main exposing (main)



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


half : number -> number
    where
        number has div : number -> number -> number
half x =
    x / 2

halfAny : a -> a -> a
    where
        a has div : a -> a -> a
halfAny x y =
    x / y

modAny : a -> a -> a
    where
        a has mod : a -> a -> a
modAny m x =
    modBy m x

three : Int
three =
    3

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
                            [ Debug.toString (half (Money 800))
                            , Debug.toString (half 3.0)
                            , Debug.toString (halfAny (Money 900) (Money 300))
                            , Debug.toString (halfAny 9.0 2.0)
                            , Debug.toString (modAny (Money 300) (Money 1000))
                            , Debug.toString (modAny three 10)
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }

