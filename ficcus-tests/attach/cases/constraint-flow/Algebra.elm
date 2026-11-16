module Algebra exposing (sum, double)


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
