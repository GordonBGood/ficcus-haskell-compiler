module Main exposing (main)



type T = T Int
    where
        f : T -> Int
        f (T n) = n


describe : a -> String
    where
        a has f : a -> z
describe x =
    Debug.toString (f x)


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (describe (T 1))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
