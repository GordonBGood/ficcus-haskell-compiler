module Main exposing (main)
import Email exposing (Email)
import Json.Encode



cmp : Email -> Email -> Order
cmp = Email.compare

enc : Email -> Json.Encode.Value
enc = Email.Email.encode


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
