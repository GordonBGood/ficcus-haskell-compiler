module K exposing (Q(..), k)


type Q = Q Int
    where
        pick : Q -> c -> c
        pick _ x = x

        idq : Q -> Q
        idq q = q


choose : a -> c -> c
    where
        a has pick : a -> c -> c
choose x y =
    pick x y



k t =
    let
        y =
            choose t
    in
    ( y, Q.idq t )
