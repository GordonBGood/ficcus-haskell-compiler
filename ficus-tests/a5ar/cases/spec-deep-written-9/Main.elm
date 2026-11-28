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





get : a -> b
    where
        a has f : a -> b
get x =
    f x


deep : a0 -> a10
    where
        a9 has f as f9 : a9 -> a10
        a8 has f as f8 : a8 -> a9
        a7 has f as f7 : a7 -> a8
        a6 has f as f6 : a6 -> a7
        a5 has f as f5 : a5 -> a6
        a4 has f as f4 : a4 -> a5
        a3 has f as f3 : a3 -> a4
        a2 has f as f2 : a2 -> a3
        a1 has f as f1 : a1 -> a2
        a0 has f as f0 : a0 -> a1
deep w =
    get (get (get (get (get (get (get (get (get (get (w))))))))))


out =
    deep (T9 (T8 (T7 (T6 (T5 (T4 (T3 (T2 (T1 (T0 42)))))))))) + 1


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
