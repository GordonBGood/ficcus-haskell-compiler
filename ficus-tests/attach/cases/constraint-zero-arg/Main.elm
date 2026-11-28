module Main exposing (main)



type Money = Money Int
    where
        zero : Money
        zero = Money 0

        add : Money -> Money -> Money
        add (Money a) (Money b) = Money (a + b)

        toInt : Money -> Int
        toInt (Money a) = a


empty : a
    where
        a has zero : a
empty =
    zero


start : Money
start =
    empty


zeros : Int -> a -> List a
    where
        a has zero : a
zeros n _ =
    List.repeat n zero


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (( Money.add empty (Money 3), start, List.length (zeros 3 (Money 1)) ))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
