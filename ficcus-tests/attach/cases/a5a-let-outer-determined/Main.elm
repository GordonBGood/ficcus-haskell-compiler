module Main exposing (main)



type T = T Int
    where
        f : T -> Int
        f (T n) = n


type W = W T
    where
        f : W -> T
        f (W t) = t


get : a -> b
    where
        a has f : a -> b
get x =
    f x

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

k w =
    let
        g x =
            ( get w, plus x x )
    in
    ( g (Money 1), g (Vec 1 1) )


out =
    k (T 5)



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
