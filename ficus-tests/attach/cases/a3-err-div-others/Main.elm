module Main exposing (main)


type Ratio
    = Ratio Int
    where
        div : Ratio -> Ratio -> Ratio
        div (Ratio a) (Ratio b) =
            Ratio (a // b)


{-| number, but no `div`; another type in the module has `div`, so `/` is typed by the member: this type is the error. -}
type Big
    = Big Int
    where
        add : Big -> Big -> Big
        add (Big a) (Big b) =
            Big (a + b)

        sub : Big -> Big -> Big
        sub (Big a) (Big b) =
            Big (a - b)

        mul : Big -> Big -> Big
        mul (Big a) (Big b) =
            Big (a * b)

        pow : Big -> Big -> Big
        pow (Big a) (Big b) =
            Big (a ^ b)

        neg : Big -> Big
        neg (Big a) =
            Big (negate a)

        abs : Big -> Big
        abs (Big a) =
            Big (Basics.abs a)

        fromInt : Int -> Big
        fromInt n =
            Big n

        compare : Big -> Big -> Order
        compare (Big a) (Big b) =
            Basics.compare a b


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (Big 6 / Big 2)
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
