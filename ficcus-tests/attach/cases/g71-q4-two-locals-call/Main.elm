module Main exposing (main)



type Money = Money Int
    where
        zero : Money
        zero = Money 0

        add : Money -> Money -> Money
        add (Money a) (Money b) = Money (a + b)

        compare : Money -> Money -> Order
        compare (Money a) (Money b) = Basics.compare a b


type Vec = Vec Int Int
    where
        zero : Vec
        zero = Vec 0 0

        add : Vec -> Vec -> Vec
        add (Vec a b) (Vec c d) = Vec (a + c) (b + d)

        compare : Vec -> Vec -> Order
        compare (Vec a b) (Vec c d) = Basics.compare ( a, b ) ( c, d )


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


stats : List a -> a -> ( a, Order )
    where
        a has zero : a
        a has add : a -> a -> a
        a has compare : a -> a -> Order
stats xs limit =
    let
        total ys =
            sum ys

        check y =
            cmp y limit
    in
    ( total xs, check (total xs) )


out =
    ( stats [ Money 1, Money 2 ] (Money 2), stats [ Vec 1 2, Vec 3 4 ] (Vec 9 0) )



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
