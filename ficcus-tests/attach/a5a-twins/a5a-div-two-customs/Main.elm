module Main exposing (main)



type Cash
    = Cash Int


type Ratio
    = Ratio Int Int


out =
    ( ( Cash 200, Ratio 4 6 ), ( Cash 3, Ratio 1 2 ), 3 / 2 )



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
