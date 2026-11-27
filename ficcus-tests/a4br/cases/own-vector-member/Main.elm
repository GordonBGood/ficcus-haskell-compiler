module Main exposing (main)

import Vector exposing (Vector)


sortW : List a -> List a
    where
        a has compare : a -> a -> Order
sortW xs =
    List.sortWith compare xs


len : Vector a -> Int
len (Vector.Vector _ n) =
    n


lines : List String
lines =
    [ Debug.toString ( compare (Vector.fromList [ 1, 2 ]) (Vector.fromList [ 3 ]), compare (Vector.fromList [ 7 ]) (Vector.fromList []) )
    , Debug.toString (List.map len (sortW [ Vector.fromList [ 5, 5 ], Vector.fromList [ 9 ] ]))
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
