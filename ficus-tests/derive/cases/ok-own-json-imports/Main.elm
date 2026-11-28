module Main exposing (main)
import Json.Encode as E
import Json.Decode as D



type Payload = Payload Int where derive encode, decoder

enc : Int -> E.Value
enc = E.int

dec : D.Decoder Int
dec = D.int


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (E.encode 0 (enc 3))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
