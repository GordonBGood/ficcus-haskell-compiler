module Algebra.Extra exposing (sumTwice)

import Algebra


sumTwice : List a -> a
    where
        a has zero : a
        a has add : a -> a -> a
sumTwice xs =
    Algebra.double (Algebra.sum xs)
