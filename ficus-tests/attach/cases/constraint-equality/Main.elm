module Main exposing (main)



type Money = Money Int
    where
        zero : Money
        zero = Money 0

        add : Money -> Money -> Money
        add (Money a) (Money b) = Money (a + b)

        toInt : Money -> Int
        toInt (Money a) = a


countZeros : List a -> Int
    where
        a has zero : a
countZeros xs =
    List.length (List.filter (\x -> x == zero) xs)


biggest : List a -> Int
    where
        a has toInt : a -> Int
biggest xs =
    List.foldl max 0 (List.map toInt xs)


scale : number -> a -> ( number, a )
    where
        a has add : a -> a -> a
scale n x =
    ( n * 2, add x x )


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (( countZeros [ Money 0, Money 1, Money 0 ], biggest [ Money 3, Money 9, Money 4 ], scale 3 (Money 5) ))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
