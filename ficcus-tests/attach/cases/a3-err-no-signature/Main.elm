module Main exposing (main)


type Money
    = Money Int
    where
        compare (Money a) (Money b) =
            Basics.compare a b


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (Money 1)
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
