module Main exposing (main)



type Money = Money Int
    where
        zero : Money
        zero = Money 0

        add : Money -> Money -> Money
        add (Money a) (Money b) = Money (a + b)

        toInt : Money -> Int
        toInt (Money a) = a


type V2 = V2 Float Float
    where
        zero : V2
        zero = V2 0 0

        add : V2 -> V2 -> V2
        add (V2 a b) (V2 c d) = V2 (a + c) (b + d)


add : Int -> Int -> Int
add a b =
    a + b


both : ( a, b ) -> ( a, b ) -> ( a, b )
    where
        a has add as addA : a -> a -> a
        b has add as addB : b -> b -> b
both ( a1, b1 ) ( a2, b2 ) =
    ( addA a1 a2, addB b1 b2 )


double : a -> a
    where
        a has add as plus : a -> a -> a
double x =
    if add 1 1 == 2 then plus x x else x


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (( both ( Money 1, V2 1 1 ) ( Money 2, V2 2 2 ), double (Money 21) ))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
