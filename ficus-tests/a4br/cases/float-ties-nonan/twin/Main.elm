module Main exposing (main)

import Dict
import Set


type alias P =
    ( Int, Float, String )


pP : Float -> String -> P
pP f s =
    ( 0, f, s )


q : P
q =
    ( 1, 0, "" )


nan : Float
nan =
    0 / 0


ps : List P
ps =
    [ pP 1 "a", q, pP 7 "n", pP -0.0 "m", pP 0 "z", pP 0 "a", pP (1 / 0) "i", pP 7 "n", pP -0.0 "a" ]


lines : List String
lines =
    [ Debug.toString (List.map (\a -> List.map (\b -> compare a b) ps) ps)
    , Debug.toString (List.map Tuple.second (List.sortBy Tuple.first (List.indexedMap (\i p -> ( [ p ], i )) ps)))
    , Debug.toString (List.map Tuple.second (List.sortWith (\( a, _ ) ( b, _ ) -> compare a b) (List.indexedMap (\i p -> ( p, i )) ps)))
    , Debug.toString (Dict.size (Dict.fromList (List.map (\p -> ( p, () )) ps)), Set.size (Set.fromList (List.map (\p -> [ p ]) ps)))
    , Debug.toString (List.map (\a -> List.map (\b -> a == b) ps) ps)
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
