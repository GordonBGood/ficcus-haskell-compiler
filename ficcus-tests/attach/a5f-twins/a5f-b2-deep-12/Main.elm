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

deep w =
    f0 (f1 (f2 (f3 (f4 (f5 (f6 (f7 (f8 (f9 (f10 (f11 (f12 (w)))))))))))))


out =
    deep (T12 (T11 (T10 (T9 (T8 (T7 (T6 (T5 (T4 (T3 (T2 (T1 (T0 42))))))))))))) + 1



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
