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


move : a -> a -> a
    where
        a has add : a -> a -> a
move base y =
    plus y base


shift : a -> List a -> List a
    where
        a has add : a -> a -> a
shift base xs =
    List.map (move base) xs


out =
    ( shift (Money 10) [ Money 1, Money 2 ], shift (Vec 10 20) [ Vec 1 2 ] )



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
