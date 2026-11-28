module Main exposing (main)

import Vector exposing (Vector)



len : Vector a -> Int
len (Vector.Vector _ n) =
    n


lines : List String
lines =
    [ Debug.toString ( Vector.compareV (Vector.fromList [ 1, 2 ]) (Vector.fromList [ 3 ]), Vector.compareV (Vector.fromList [ \x -> x ]) (Vector.fromList []) )
    , Debug.toString (List.map len (List.sortWith Vector.compareV [ Vector.fromList [ 5, 5 ], Vector.fromList [ 9 ], Vector.fromList [] ]))
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
