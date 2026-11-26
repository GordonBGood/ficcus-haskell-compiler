module Main exposing (main)



type Money
    = Money Int
    where
        zero : Money
        zero =
            Money 7

        add : Money -> Money -> Money
        add (Money a) (Money b) =
            Money (a + b)

sum : List a -> a
    where
        a has zero : a
        a has add : a -> a -> a
sum xs =
    List.foldl add zero xs


out =
    ( sum [ Money 1, Money 2 ], sum [ 4 ] )



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
