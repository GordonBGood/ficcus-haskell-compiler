module Main exposing (main)



type Money = Money Int
    where
        zero : Money
        zero = Money 0

        add : Money -> Money -> Money
        add (Money a) (Money b) = Money (a + b)

        toInt : Money -> Int
        toInt (Money a) = a


type V2 = V2 Float Float
    where
        zero : V2
        zero = V2 0 0

        add : V2 -> V2 -> V2
        add (V2 a b) (V2 c d) = V2 (a + c) (b + d)


sum : List a -> a
    where
        a has zero : a
        a has add : a -> a -> a
sum xs =
    List.foldl add zero xs


double : a -> a
    where
        a has add : a -> a -> a
double x =
    add x x


sumTwice : List a -> a
    where
        a has zero : a
        a has add : a -> a -> a
sumTwice xs =
    double (sum xs)


sumRec : List a -> a
    where
        a has zero : a
        a has add : a -> a -> a
sumRec xs =
    case xs of
        [] ->
            zero

        x :: rest ->
            add x (sumRec rest)


sumLocal : List a -> a
    where
        a has zero : a
        a has add as plus : a -> a -> a
sumLocal xs =
    let
        go acc ys =
            case ys of
                [] ->
                    acc

                y :: more ->
                    go (plus acc y) more

        doubled =
            List.map (\x -> plus x x) xs
    in
    go zero doubled


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (( sumTwice [ Money 1, Money 2 ], sumRec [ V2 1 1, V2 2 2 ], sumLocal [ Money 1, Money 2 ] ))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
