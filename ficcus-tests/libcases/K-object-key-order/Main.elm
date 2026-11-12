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


text : String
text =
    "{\"b\":1,\"2\":2,\"a\":3,\"1\":4,\"01\":5,\"4294967294\":6,\"4294967295\":7,\"-1\":8,\"1.5\":9,\"0\":10,\"\":11,\"10\":12}"


reencode : String -> Result () String
reencode s =
    D.decodeString D.value s |> Result.map (E.encode 0) |> Result.mapError (always ())


pairs : String -> Result () (List ( String, Int ))
pairs s =
    D.decodeString (D.keyValuePairs D.int) s |> Result.mapError (always ())


run : () -> Int
run _ =
    List.length
        [ Debug.log "parse-print" (reencode text) |> always ()
        , Debug.log "parse-pairs" (pairs text) |> always ()
        , Debug.log "parse-duplicate" (reencode "{\"x\":1,\"7\":2,\"x\":3,\"3\":4,\"7\":5}") |> always ()
        , Debug.log "parse-nested" (reencode "{\"z\":{\"b\":1,\"1\":2},\"0\":[{\"y\":1,\"5\":2,\"4\":3}]}") |> always ()
        , Debug.log "object" (E.encode 0 (E.object [ ( "b", E.int 1 ), ( "10", E.int 2 ), ( "9", E.int 3 ), ( "a", E.int 4 ), ( "09", E.int 5 ) ])) |> always ()
        , Debug.log "object-indent" (E.encode 2 (E.object [ ( "k", E.null ), ( "2", E.bool True ), ( "1", E.string "s" ) ])) |> always ()
        , Debug.log "object-duplicate" (E.encode 0 (E.object [ ( "b", E.int 1 ), ( "3", E.int 2 ), ( "b", E.int 3 ), ( "3", E.int 4 ), ( "1", E.int 5 ) ])) |> always ()
        , Debug.log "object-pairs" (D.decodeValue (D.keyValuePairs D.int) (E.object [ ( "b", E.int 1 ), ( "10", E.int 2 ), ( "9", E.int 3 ) ]) |> Result.mapError (always ())) |> always ()
        , Debug.log "dict" (E.encode 0 (E.dict identity E.int (Dict.fromList [ ( "b", 1 ), ( "10", 2 ), ( "9", 3 ), ( "100", 4 ), ( "a", 5 ) ]))) |> always ()
        , Debug.log "dict-int-keys" (E.encode 0 (E.dict String.fromInt E.int (Dict.fromList [ ( 30, 1 ), ( -2, 2 ), ( 4, 3 ), ( 100, 4 ) ]))) |> always ()
        , Debug.log "dict-decode" (D.decodeString (D.dict D.int) "{\"b\":1,\"10\":2,\"9\":3}" |> Result.mapError (always ())) |> always ()
        , Debug.log "limit" (E.encode 0 (E.object [ ( "4294967295", E.int 1 ), ( "4294967294", E.int 2 ), ( "4294967296", E.int 3 ), ( "5", E.int 4 ) ])) |> always ()
        , Debug.log "equal-any-order" (E.object [ ( "a", E.int 1 ), ( "1", E.int 2 ) ] == E.object [ ( "1", E.int 2 ), ( "a", E.int 1 ) ]) |> always ()
        , Debug.log "field-after-reorder" (D.decodeString (D.field "9" D.int) "{\"b\":1,\"10\":2,\"9\":3}" |> Result.mapError (always ())) |> always ()
        ]
