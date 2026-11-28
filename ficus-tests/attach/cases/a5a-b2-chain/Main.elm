module Main exposing (main)



type T = T Int
    where
        g : T -> String
        g (T n) = "T" ++ String.fromInt n

type W = W T
    where
        f : W -> T
        f (W t) = t

        g : W -> String
        g _ = "W"

describe : a -> String
    where
        a has f : a -> b
        b has g : b -> String
describe x =
    g (f x)


out =
    describe (W (T 7))



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
