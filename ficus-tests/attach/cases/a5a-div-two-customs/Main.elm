module Main exposing (main)



type Cash
    = Cash Int
    where
        div : Cash -> Cash -> Cash
        div (Cash a) (Cash b) =
            Cash (a // b)

type Ratio
    = Ratio Int Int
    where
        div : Ratio -> Ratio -> Ratio
        div (Ratio a b) (Ratio c d) =
            Ratio (a * d) (b * c)

half x y =
    x / y


out =
    let
        q a b =
            a / b
    in
    ( ( half (Cash 800) (Cash 4), half (Ratio 1 2) (Ratio 3 4) ), ( q (Cash 9) (Cash 3), q (Ratio 1 1) (Ratio 2 1) ), half 3 2 )



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
