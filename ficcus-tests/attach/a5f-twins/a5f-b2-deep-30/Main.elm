module Main exposing (main)



type T0
    = T0 Int


f0 : T0 -> Int
f0 (T0 k) =
    k

type T1
    = T1 T0


f1 : T1 -> T0
f1 (T1 t) =
    t

type T2
    = T2 T1


f2 : T2 -> T1
f2 (T2 t) =
    t

type T3
    = T3 T2


f3 : T3 -> T2
f3 (T3 t) =
    t

type T4
    = T4 T3


f4 : T4 -> T3
f4 (T4 t) =
    t

type T5
    = T5 T4


f5 : T5 -> T4
f5 (T5 t) =
    t

type T6
    = T6 T5


f6 : T6 -> T5
f6 (T6 t) =
    t

type T7
    = T7 T6


f7 : T7 -> T6
f7 (T7 t) =
    t

type T8
    = T8 T7


f8 : T8 -> T7
f8 (T8 t) =
    t

type T9
    = T9 T8


f9 : T9 -> T8
f9 (T9 t) =
    t

type T10
    = T10 T9


f10 : T10 -> T9
f10 (T10 t) =
    t

type T11
    = T11 T10


f11 : T11 -> T10
f11 (T11 t) =
    t

type T12
    = T12 T11


f12 : T12 -> T11
f12 (T12 t) =
    t

type T13
    = T13 T12


f13 : T13 -> T12
f13 (T13 t) =
    t

type T14
    = T14 T13


f14 : T14 -> T13
f14 (T14 t) =
    t

type T15
    = T15 T14


f15 : T15 -> T14
f15 (T15 t) =
    t

type T16
    = T16 T15


f16 : T16 -> T15
f16 (T16 t) =
    t

type T17
    = T17 T16


f17 : T17 -> T16
f17 (T17 t) =
    t

type T18
    = T18 T17


f18 : T18 -> T17
f18 (T18 t) =
    t

type T19
    = T19 T18


f19 : T19 -> T18
f19 (T19 t) =
    t

type T20
    = T20 T19


f20 : T20 -> T19
f20 (T20 t) =
    t

type T21
    = T21 T20


f21 : T21 -> T20
f21 (T21 t) =
    t

type T22
    = T22 T21


f22 : T22 -> T21
f22 (T22 t) =
    t

type T23
    = T23 T22


f23 : T23 -> T22
f23 (T23 t) =
    t

type T24
    = T24 T23


f24 : T24 -> T23
f24 (T24 t) =
    t

type T25
    = T25 T24


f25 : T25 -> T24
f25 (T25 t) =
    t

type T26
    = T26 T25


f26 : T26 -> T25
f26 (T26 t) =
    t

type T27
    = T27 T26


f27 : T27 -> T26
f27 (T27 t) =
    t

type T28
    = T28 T27


f28 : T28 -> T27
f28 (T28 t) =
    t

type T29
    = T29 T28


f29 : T29 -> T28
f29 (T29 t) =
    t

type T30
    = T30 T29


f30 : T30 -> T29
f30 (T30 t) =
    t

deep w =
    f0 (f1 (f2 (f3 (f4 (f5 (f6 (f7 (f8 (f9 (f10 (f11 (f12 (f13 (f14 (f15 (f16 (f17 (f18 (f19 (f20 (f21 (f22 (f23 (f24 (f25 (f26 (f27 (f28 (f29 (f30 (w)))))))))))))))))))))))))))))))


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
