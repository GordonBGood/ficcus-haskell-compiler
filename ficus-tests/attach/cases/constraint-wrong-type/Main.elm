module Main exposing (main)



type T = T Int
    where
        zero : T
        zero = T 0

        plus : T -> Int -> T
        plus a _ = a


sum : List a -> a
    where
        a has zero : a
        a has plus : a -> a -> a
sum xs =
    List.foldl plus zero xs


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (sum [ T 1 ])
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
