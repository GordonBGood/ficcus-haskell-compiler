module Main exposing (main)



type Money
    = Money Int


type Vec
    = Vec Int Int


out =
    ( Money 0, Money 5, Vec 1 1 )



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
