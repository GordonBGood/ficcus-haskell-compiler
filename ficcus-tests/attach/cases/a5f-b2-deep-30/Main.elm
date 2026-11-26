module Main exposing (main)



type T0 = T0 Int
    where
        f : T0 -> Int
        f (T0 k) = k

type T1 = T1 T0
    where
        f : T1 -> T0
        f (T1 t) = t

type T2 = T2 T1
    where
        f : T2 -> T1
        f (T2 t) = t

type T3 = T3 T2
    where
        f : T3 -> T2
        f (T3 t) = t

type T4 = T4 T3
    where
        f : T4 -> T3
        f (T4 t) = t

type T5 = T5 T4
    where
        f : T5 -> T4
        f (T5 t) = t

type T6 = T6 T5
    where
        f : T6 -> T5
        f (T6 t) = t

type T7 = T7 T6
    where
        f : T7 -> T6
        f (T7 t) = t

type T8 = T8 T7
    where
        f : T8 -> T7
        f (T8 t) = t

type T9 = T9 T8
    where
        f : T9 -> T8
        f (T9 t) = t

type T10 = T10 T9
    where
        f : T10 -> T9
        f (T10 t) = t

type T11 = T11 T10
    where
        f : T11 -> T10
        f (T11 t) = t

type T12 = T12 T11
    where
        f : T12 -> T11
        f (T12 t) = t

type T13 = T13 T12
    where
        f : T13 -> T12
        f (T13 t) = t

type T14 = T14 T13
    where
        f : T14 -> T13
        f (T14 t) = t

type T15 = T15 T14
    where
        f : T15 -> T14
        f (T15 t) = t

type T16 = T16 T15
    where
        f : T16 -> T15
        f (T16 t) = t

type T17 = T17 T16
    where
        f : T17 -> T16
        f (T17 t) = t

type T18 = T18 T17
    where
        f : T18 -> T17
        f (T18 t) = t

type T19 = T19 T18
    where
        f : T19 -> T18
        f (T19 t) = t

type T20 = T20 T19
    where
        f : T20 -> T19
        f (T20 t) = t

type T21 = T21 T20
    where
        f : T21 -> T20
        f (T21 t) = t

type T22 = T22 T21
    where
        f : T22 -> T21
        f (T22 t) = t

type T23 = T23 T22
    where
        f : T23 -> T22
        f (T23 t) = t

type T24 = T24 T23
    where
        f : T24 -> T23
        f (T24 t) = t

type T25 = T25 T24
    where
        f : T25 -> T24
        f (T25 t) = t

type T26 = T26 T25
    where
        f : T26 -> T25
        f (T26 t) = t

type T27 = T27 T26
    where
        f : T27 -> T26
        f (T27 t) = t

type T28 = T28 T27
    where
        f : T28 -> T27
        f (T28 t) = t

type T29 = T29 T28
    where
        f : T29 -> T28
        f (T29 t) = t

type T30 = T30 T29
    where
        f : T30 -> T29
        f (T30 t) = t

get : a -> b
    where
        a has f : a -> b
get x =
    f x

deep w =
    get (get (get (get (get (get (get (get (get (get (get (get (get (get (get (get (get (get (get (get (get (get (get (get (get (get (get (get (get (get (get (w)))))))))))))))))))))))))))))))


out =
    deep (T30 (T29 (T28 (T27 (T26 (T25 (T24 (T23 (T22 (T21 (T20 (T19 (T18 (T17 (T16 (T15 (T14 (T13 (T12 (T11 (T10 (T9 (T8 (T7 (T6 (T5 (T4 (T3 (T2 (T1 (T0 42))))))))))))))))))))))))))))))) + 1



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
