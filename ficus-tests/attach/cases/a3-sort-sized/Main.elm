module Main exposing (main)

import Int8
import Word64


logAll : List String -> ()
logAll ls =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () ls


lines : List String
lines =
    [ "word64 " ++ String.join " " (List.map Word64.toString (List.sort [ Word64.maxValue, Word64.fromInt 5, Word64.fromInt 0, Word64.fromInt 7 ]))
    , "word64 by " ++ String.join " " (List.map Tuple.second (List.sortBy Tuple.first [ ( Word64.maxValue, "max" ), ( Word64.fromInt 1, "one" ), ( Word64.fromInt 9223372036854775807, "half" ) ]))
    , "int8 " ++ String.join " " (List.map Int8.toString (List.sort [ Int8.fromInt -3, Int8.fromInt 100, Int8.fromInt -128, Int8.fromInt 0 ]))
    ]


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> let _ = logAll lines in ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
