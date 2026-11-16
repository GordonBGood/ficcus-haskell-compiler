module Main exposing (main)



type Money = Money Int
    where
        zero : Money
        zero = Money 0

        add : Money -> Money -> Money
        add (Money a) (Money b) = Money (a + b)

        toInt : Money -> Int
        toInt (Money a) = a


add : Int -> Int -> Int
add a b =
    a * b


total : List Money -> Money
total =
    List.foldl Money.add Money.zero


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" ([ Money.toInt (total [ Money 1, Money 2, Money 39 ]), Money 5 |> Money.add (Money 6) |> Money.toInt, add 3 4 ])
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
