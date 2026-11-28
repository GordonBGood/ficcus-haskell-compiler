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





get : a -> b
    where
        a has f : a -> b
get x =
    f x


deep w =
    get (get (get (get (get (get (get (get (get (get (get (get (get (w)))))))))))))


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
