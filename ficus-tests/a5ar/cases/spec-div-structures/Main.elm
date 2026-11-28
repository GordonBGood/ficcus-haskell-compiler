module Main exposing (main)
import Float32 exposing (Float32)

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

halfAll xs =
    List.map (\x -> x / 2) xs


halfLet xs =
    let
        h x =
            x / 2
    in
    List.map h xs


halfRec r =
    { r | v = r.v / 2 }


halfMaybe m =
    Maybe.map (\x -> x / 4) m


out =
    ( ( halfAll [ 3, 5 ], halfAll [ Cash 300 ], List.map Float32.toString (halfAll [ Float32.fromFloat 3 ]) )
    , ( halfLet [ 1 ], halfLet [ Cash 100 ], List.map Float32.toString (halfLet [ Float32.fromFloat 1 ]) )
    , ( ( halfRec { v = 9, w = 1 }, halfRec { v = Cash 900, w = "x" } ), ( halfMaybe (Just (Cash 800)), halfMaybe (Just 2) ) )
    )


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
