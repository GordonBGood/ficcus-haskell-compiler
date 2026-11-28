module Main exposing (main)
import Json.Encode



type Color
    = Red
    | Green
    | Blue
    where
        derive compare, hash, toString, encode, decoder, minValue, maxValue, succ, pred, enumerate

        name : Color -> String
        name c =
            case c of
                Red -> "red"
                Green -> "green"
                Blue -> "blue"


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (Json.Encode.encode 0 (Color.encode Red))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
