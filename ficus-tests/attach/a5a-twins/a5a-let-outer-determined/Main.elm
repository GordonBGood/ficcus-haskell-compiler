module Main exposing (main)



type Money
    = Money Int


type Vec
    = Vec Int Int


out =
    ( ( 5, Money 2 ), ( 5, Vec 2 2 ) )



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
