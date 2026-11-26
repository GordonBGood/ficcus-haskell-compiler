module Main exposing (main)

type Money = Money Int
    where
        zero : Money
        zero = Money 0

        add : Money -> Money -> Money
        add (Money a) (Money b) = Money (a + b)

        compare : Money -> Money -> Order
        compare (Money a) (Money b) = Basics.compare a b

        addTo : Money -> Int -> Money
        addTo (Money a) n = Money (a + n)


type Vec = Vec Int Int
    where
        zero : Vec
        zero = Vec 0 0

        add : Vec -> Vec -> Vec
        add (Vec a b) (Vec c d) = Vec (a + c) (b + d)

        compare : Vec -> Vec -> Order
        compare (Vec a b) (Vec c d) = Basics.compare ( a, b ) ( c, d )

        addTo : Vec -> Int -> Vec
        addTo (Vec a b) n = Vec (a + n) (b + n)


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


addN : a -> b -> a
    where
        a has addTo : a -> b -> a
addN x n =
    addTo x n

f m v =
    let
        ev n x =
            if n == 0 then x else od (n - 1) (plus x x)

        od n x =
            if n == 0 then x else ev (n - 1) x
    in
    ( ev 3 m, od 3 v )


out =
    f (Money 1) (Vec 1 2)


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
