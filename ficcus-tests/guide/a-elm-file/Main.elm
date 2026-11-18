module Main exposing (main)


type Money
    = Money Int
    where
        zero : Money
        zero =
            Money 0

        add : Money -> Money -> Money
        add (Money a) (Money b) =
            Money (a + b)

        toInt : Money -> Int
        toInt (Money a) =
            a


total : List Money -> Money
total =
    List.foldl Money.add Money.zero


report : () -> ()
report _ =
    let
        _ =
            Debug.log "total" (Money.toInt (total [ Money 1, Money 2, Money 39 ]))

        _ =
            Debug.log "piped" (Money 5 |> Money.add (Money 6) |> Money.toInt)
    in
    ()


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( report (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
