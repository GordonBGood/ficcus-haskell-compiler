module Main exposing (main)

type Cash = Cash Int
    where
        add : Cash -> Cash -> Cash
        add (Cash a) (Cash b) = Cash (a + b)

        sub : Cash -> Cash -> Cash
        sub (Cash a) (Cash b) = Cash (a - b)

        mul : Cash -> Cash -> Cash
        mul (Cash a) (Cash b) = Cash (a * b)

        pow : Cash -> Cash -> Cash
        pow (Cash a) (Cash b) = Cash (a ^ b)

        neg : Cash -> Cash
        neg (Cash a) = Cash (negate a)

        abs : Cash -> Cash
        abs (Cash a) = Cash (Basics.abs a)

        fromInt : Int -> Cash
        fromInt n = Cash (n * 100)

        compare : Cash -> Cash -> Order
        compare (Cash a) (Cash b) = Basics.compare a b

        div : Cash -> Cash -> Cash
        div (Cash a) (Cash b) = Cash ((a * 100) // b)

        idiv : Cash -> Cash -> Cash
        idiv (Cash a) (Cash b) = Cash ((a * 100) // b)

        mod : Cash -> Cash -> Cash
        mod (Cash a) (Cash b) = Cash (modBy b a)

        rem : Cash -> Cash -> Cash
        rem (Cash a) (Cash b) = Cash (remainderBy b a)


type Ratio = Ratio Int Int
    where
        div : Ratio -> Ratio -> Ratio
        div (Ratio a b) (Ratio c d) = Ratio (a * d) (b * c)

ev n x =
    if n <= 0 then x else od (n - 1) (x / 2)


od n x =
    if n <= 0 then x else ev (n - 1) x


out =
    ev 2 8


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
