module Main exposing (main)



type Cash
    = Cash Int
    where
        add : Cash -> Cash -> Cash
        add (Cash a) (Cash b) = Cash (a + b)

        sub : Cash -> Cash -> Cash
        sub (Cash a) (Cash b) = Cash (a - b)

        mul : Cash -> Cash -> Cash
        mul (Cash a) (Cash b) = Cash (a * b // 100)

        pow : Cash -> Cash -> Cash
        pow (Cash a) (Cash b) = Cash (a ^ (b // 100))

        neg : Cash -> Cash
        neg (Cash a) = Cash (negate a)

        abs : Cash -> Cash
        abs (Cash a) = Cash (Basics.abs a)

        fromInt : Int -> Cash
        fromInt n = Cash (n * 100)

        compare : Cash -> Cash -> Order
        compare (Cash a) (Cash b) = Basics.compare a b

        eq : Cash -> Cash -> Bool
        eq (Cash a) (Cash b) = a == b

        div : Cash -> Cash -> Cash
        div (Cash a) (Cash b) = Cash (a * 100 // b)

        idiv : Cash -> Cash -> Cash
        idiv (Cash a) (Cash b) = Cash ((a // b) * 100)

        mod : Cash -> Cash -> Cash
        mod (Cash m) (Cash x) = Cash (modBy m x)

        rem : Cash -> Cash -> Cash
        rem (Cash m) (Cash x) = Cash (remainderBy m x)


out =
    let
        h y =
            modBy 4 y
    in
    ( h 9, h 10 )



main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" out
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
