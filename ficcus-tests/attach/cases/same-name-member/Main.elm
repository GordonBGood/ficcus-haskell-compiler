module Main exposing (main)



type Money = Money Int
    where
        zero : Money
        zero = Money 0

        add : Money -> Money -> Money
        add (Money a) (Money b) = Money (a + b)

        toInt : Money -> Int
        toInt (Money a) = a


type Count = Count Int
    where
        zero : Count
        zero = Count 100

        add : Count -> Count -> Count
        add (Count a) (Count b) = Count (a + b + 1000)

        toInt : Count -> Int
        toInt (Count a) = a


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" ([ Money.toInt (Money.add (Money 1) Money.zero), Count.toInt (Count.add (Count 1) Count.zero) ])
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
