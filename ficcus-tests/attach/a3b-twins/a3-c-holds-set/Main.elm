module Main exposing (main)

import Set

type Ver
    = Ver Int


verKey : Ver -> Int
verKey (Ver n) =
    negate n

lines : List String
lines =
    [ Debug.toString (Set.size (Set.fromList [ List.map verKey [ Ver 1 ], List.map verKey [ Ver 2 ] ]))
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
