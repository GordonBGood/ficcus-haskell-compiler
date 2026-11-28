module Main exposing (main)



type Nat = Zero | Succ Nat
    where
        fromInt : Int -> Nat
        fromInt n =
            if n <= 0 then
                Zero

            else
                Succ (Nat.fromInt (n - 1))

        isEven : Nat -> Bool
        isEven n =
            case n of
                Zero ->
                    True

                Succ m ->
                    Nat.isOdd m

        isOdd : Nat -> Bool
        isOdd n =
            case n of
                Zero ->
                    False

                Succ m ->
                    Nat.isEven m


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" ([ Nat.isEven (Nat.fromInt 10), Nat.isEven (Nat.fromInt 7), Nat.isOdd (Nat.fromInt 7) ])
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
