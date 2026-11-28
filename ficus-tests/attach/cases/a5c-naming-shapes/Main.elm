module Main exposing (main)



type Money
    = Money Int
    where
        scale : Money -> Int -> Money
        scale (Money a) k =
            Money (a * k)


type Vec
    = Vec Float Float
    where
        scale : Float -> Vec -> Vec
        scale k (Vec a b) =
            Vec (a * k) (b * k)


out =
    scale (Money 2) 3



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
