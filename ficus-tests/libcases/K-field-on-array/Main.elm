module Main exposing (main)

import Array
import Bitwise
import Char
import Dict
import Set
import Json.Decode as D
import Json.Encode as E




main : Program () Int ()
main =
    Platform.worker
        { init = \_ -> ( run (), Cmd.none )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


dec : D.Decoder a -> String -> Result () a
dec d s =
    D.decodeString d s |> Result.mapError (always ())


msg : D.Decoder a -> String -> Result String a
msg d s =
    D.decodeString d s |> Result.mapError D.errorToString


run : () -> Int
run _ =
    List.length
        [ Debug.log "length" (dec (D.field "length" D.int) "[1,2,3]") |> always ()
        , Debug.log "length-empty" (dec (D.field "length" D.int) "[]") |> always ()
        , Debug.log "length-float" (dec (D.field "length" D.float) "[true]") |> always ()
        , Debug.log "length-wrong-type" (msg (D.field "length" D.string) "[1,2]") |> always ()
        , Debug.log "length-of-string" (dec (D.field "length" D.int) "\"abc\"") |> always ()
        , Debug.log "length-of-object" (dec (D.field "length" D.int) "{\"a\":1}") |> always ()
        , Debug.log "length-key-of-object" (dec (D.field "length" D.int) "{\"length\":7}") |> always ()
        , Debug.log "index-0" (dec (D.field "0" D.int) "[10,20,30]") |> always ()
        , Debug.log "index-2" (dec (D.field "2" D.int) "[10,20,30]") |> always ()
        , Debug.log "index-too-large" (msg (D.field "3" D.int) "[10,20,30]") |> always ()
        , Debug.log "index-leading-zero" (dec (D.field "01" D.int) "[10,20,30]") |> always ()
        , Debug.log "index-negative" (dec (D.field "-1" D.int) "[10,20,30]") |> always ()
        , Debug.log "index-fraction" (dec (D.field "1.0" D.int) "[10,20,30]") |> always ()
        , Debug.log "index-space" (dec (D.field " 1" D.int) "[10,20,30]") |> always ()
        , Debug.log "index-empty-name" (dec (D.field "" D.int) "[10,20,30]") |> always ()
        , Debug.log "index-wrong-type" (msg (D.field "1" D.string) "[10,20,30]") |> always ()
        , Debug.log "at" (dec (D.at [ "1", "0", "x" ] D.int) "[0,[{\"x\":5}]]") |> always ()
        , Debug.log "at-length" (dec (D.at [ "a", "length" ] D.int) "{\"a\":[1,2,3,4]}") |> always ()
        , Debug.log "value" (dec (D.field "1" D.value |> D.map (E.encode 0)) "[1,{\"k\":[]}]") |> always ()
        , Debug.log "maybe" (dec (D.maybe (D.field "5" D.int)) "[1]") |> always ()
        , Debug.log "oneOf" (dec (D.oneOf [ D.field "x" D.int, D.field "length" D.int ]) "[1,2]") |> always ()
        , Debug.log "on-null" (msg (D.field "length" D.int) "null") |> always ()
        , Debug.log "on-number" (dec (D.field "0" D.int) "5") |> always ()
        ]
