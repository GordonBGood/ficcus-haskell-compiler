module Main exposing (main)



type alias Meters =
    Float
    where
        add : Meters -> Meters -> Meters
        add a b =
            a + b


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (1)
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
