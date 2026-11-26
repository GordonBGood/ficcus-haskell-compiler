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

f x =
    let
        g y =
            Debug.toString ( y, 7 // 2, 7 / 2 )
    in
    g x


h y =
    y // 4


k =
    modBy 3 10


mm =
    let
        q z =
            z / 2
    in
    ( q 3, q 4.5 )


r a b =
    ( remainderBy a b, modBy a b )


v =
    7 / 2


out =
    ( ( f 1, h 9, k ), ( mm, r 3 -7, v ) )


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
