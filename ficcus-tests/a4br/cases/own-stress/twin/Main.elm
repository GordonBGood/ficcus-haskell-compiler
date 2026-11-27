module Main exposing (main)

import Dict exposing (Dict)
import Set exposing (Set)


type alias Key =
    ( Int, ( String, List (List Int), ( ( Int, List (List Float), List String ), List String ) ), Int )


mkKey : Int -> Key
mkKey i =
    if modBy 11 i == 10 then
        ( 1, ( "", [], ( ( 0, [], [] ), [] ) ), modBy 3 i )

    else
        ( 0
        , ( String.toLower ((if modBy 2 i == 0 then "A" else "a") ++ String.fromInt (modBy 4 i))
          , if modBy 3 i == 0 then [] else [ List.range 0 (modBy 4 i) ]
          , ( if modBy 2 i == 0 then ( 0, [ [ toFloat (modBy 6 i) / 2 ] ], [] ) else ( 1, [], [ String.fromInt (modBy 3 i) ] )
            , Set.toList (Set.fromList [ String.fromInt (modBy 5 i), "k" ])
            )
          )
        , 0
        )


idx : List Int
idx =
    List.range 0 150


counts : Dict Key Int
counts =
    List.foldl (\i acc -> Dict.update (mkKey i) (\m -> Just (Maybe.withDefault 0 m + 1)) acc) Dict.empty idx


big : Dict Key Int
big =
    Dict.filter (\_ v -> v > 3) counts


lines : List String
lines =
    [ Debug.toString ( Dict.size counts, Dict.values counts )
    , Debug.toString (List.map Tuple.second (List.sortBy Tuple.first (List.map (\i -> ( mkKey i, i )) idx)))
    , Debug.toString (Set.size (Set.fromList (List.map mkKey idx)))
    , Debug.toString ( 0, 0 )
    , Debug.toString (List.map Tuple.second (List.sortBy Tuple.first [ ( Dict.toList counts, "all" ), ( Dict.toList big, "big" ), ( [], "none" ) ]))
    , Debug.toString (List.map (\i -> List.map (\j -> compare (mkKey i) (mkKey j)) (List.range 0 12)) (List.range 0 12))
    , Debug.toString (List.maximum (List.map (\i -> ( mkKey i, i )) idx) |> Maybe.map Tuple.second)
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
