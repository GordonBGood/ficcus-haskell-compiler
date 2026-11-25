module Main exposing (main)

import Finance


unwrap : Finance.Money -> Int
unwrap m =
    case m of
        Finance.Money n ->
            n


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (unwrap (Finance.fromInt 5))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
