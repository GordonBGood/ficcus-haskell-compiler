module Main exposing (main)

import Int64 exposing (Int64)
import Word16


logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    a : Int64
                    a =
                        Int64.fromParts 1 4294967295

                    b =
                        Int64.add a a

                    _ =
                        logAll
                            [ String.fromInt (Int64.hi b) ++ ":" ++ String.fromInt (Int64.lo b)
                            , String.fromInt (Word16.value (Word16.make 70000))
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
