module Main exposing (main)



type Money = Money Int
    where
        zero : Money
        zero = Money 0

        add : Money -> Money -> Money
        add (Money a) (Money b) = Money (a + b)

        show : Money -> String
        show (Money a) = "$" ++ String.fromInt a

        toInt : Money -> Int
        toInt (Money a) = a


type Pair a = Pair a a
    where
        swap : Pair a -> Pair a
        swap (Pair x y) = Pair y x

        show : Pair Int -> String
        show (Pair x y) = String.fromInt x ++ "/" ++ String.fromInt y


once : t -> t
    where
        t has swap : t -> t
once x =
    swap x


twice : t -> t
    where
        t has swap : t -> t
twice x =
    swap (swap x)


describe : t -> String
    where
        t has show : t -> String
describe x =
    "<" ++ show x ++ ">"


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (( ( twice (Pair "a" "b"), once (Pair 1 2) ), describe (Pair 3 4), describe (Money 5) ))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
