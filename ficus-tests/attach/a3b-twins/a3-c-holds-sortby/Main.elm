module Main exposing (main)


type Ver
    = Ver Int


verKey : Ver -> Int
verKey (Ver n) =
    negate n

lines : List String
lines =
    [ Debug.toString (List.map .k (List.sortBy (\r -> Tuple.mapFirst verKey r.k) [ { k = ( Ver 2, 1 ) }, { k = ( Ver 1, 1 ) } ]))
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
