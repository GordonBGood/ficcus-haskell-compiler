module Main exposing (main)



type Color
    = Red
    | Blue
    where
        derive compare, hash

        compare : Color -> Color -> Order
        compare _ _ = EQ


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
