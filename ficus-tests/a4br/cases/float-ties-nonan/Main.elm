module Main exposing (main)

import Dict
import Set


type P
    = P Float String
    | Q
    where
        derive compare, hash


nan : Float
nan =
    0 / 0


ps : List P
ps =
    [ P 1 "a", Q, P 7 "n", P -0.0 "m", P 0 "z", P 0 "a", P (1 / 0) "i", P 7 "n", P -0.0 "a" ]


lines : List String
lines =
    [ Debug.toString (List.map (\a -> List.map (\b -> compare a b) ps) ps)
    , Debug.toString (List.map Tuple.second (List.sortBy Tuple.first (List.indexedMap (\i p -> ( { k = Just p }, i )) ps)))
    , Debug.toString (List.map Tuple.second (List.sortWith (\( a, _ ) ( b, _ ) -> compare a b) (List.indexedMap (\i p -> ( p, i )) ps)))
    , Debug.toString (Dict.size (Dict.fromList (List.map (\p -> ( p, () )) ps)), Set.size (Set.fromList (List.map Just ps)))
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
