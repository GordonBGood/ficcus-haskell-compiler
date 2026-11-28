module Main exposing (main)

import Dict


lines : List String
lines =
    [ Debug.toString (List.sort [ { a = Just 2, b = "x" }, { a = Nothing, b = "y" }, { a = Just 1, b = "z" } ] |> List.map .b)
    , Debug.toString (Dict.keys (Dict.fromList [ ( Ok 1, () ), ( Err "e", () ), ( Ok 0, () ) ]))
    , Debug.toString (compare (Just 1) Nothing)
    ]


logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> let _ = logAll lines in ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
