module Main exposing (main)

import Int32 exposing (Int32)


logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    a : Int32
                    a =
                        Int32.fromInt 2147483647

                    _ =
                        logAll [ String.fromInt (Int32.toInt (Int32.add a a)) ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
