module Main exposing (main)



type Color
    = Red
    | Blue
    where
        derive compare

        larger : Color -> Color -> Color
        larger a b =
            if compare a b == GT then a else b


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
