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

sum : List a -> a
    where
        a has zero : a
        a has add : a -> a -> a
sum xs =
    List.foldl add zero xs


plus : a -> a -> a
    where
        a has add : a -> a -> a
plus x y =
    add x y


cmp : a -> a -> Order
    where
        a has compare : a -> a -> Order
cmp x y =
    compare x y

halve : a -> a -> a
    where
        a has div : a -> a -> a
halve x y =
    x / y

three =
    plus 1 2

oneHalf =
    halve 3 2


out =
    ( three, oneHalf, ( 7 / 2, 7 // 2, modBy 3 7 ) )



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
