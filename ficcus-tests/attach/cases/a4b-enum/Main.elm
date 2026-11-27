module Main exposing (main)

import Dict
import Set


type Color
    = Red
    | Green
    | Blue
    where
        derive compare


name : Color -> String
name c =
    case c of
        Red ->
            "Red"

        Green ->
            "Green"

        Blue ->
            "Blue"


names : List Color -> String
names cs =
    String.join "," (List.map name cs)


colors : List Color
colors =
    [ Blue, Red, Green, Red ]


lines : List String
lines =
    [ Debug.toString (List.map (\a -> List.map (\b -> Color.compare a b) colors) colors)
    , Debug.toString (List.map (\a -> List.map (\b -> compare a b) colors) colors)
    , Debug.toString (List.map (\a -> List.map (\b -> ( a < b, a <= b, ( a > b, a >= b ) )) colors) colors)
    , names (List.sort colors)
    , names (List.sortWith Color.compare colors)
    , names (List.reverse (List.sortBy identity colors))
    , names [ max Red Blue, min Green Blue, max Green Green ]
    , Debug.toString ( Maybe.map name (List.maximum colors), Maybe.map name (List.minimum colors) )
    , String.join ";" (List.map (\( c, i ) -> name c ++ String.fromInt i) (Dict.toList (Dict.fromList (List.indexedMap (\i c -> ( c, i )) colors))))
    , names (Set.toList (Set.fromList colors))
    , Debug.toString (Dict.values (Dict.fromList [ ( ( Green, 1 ), "a" ), ( ( Red, 2 ), "b" ), ( ( Green, 0 ), "c" ), ( ( Blue, -1 ), "d" ) ]))
    , Debug.toString ( compare [ Red, Blue ] [ Red, Green ], compare [ Blue ] [ Blue, Red ], [ Green ] < [ Blue ] )
    , Debug.toString ( Dict.get Green (Dict.fromList [ ( Red, 1 ), ( Green, 2 ) ]), Set.member Blue (Set.fromList [ Red ]) )
    , Debug.toString (List.map (\c -> Color.compare c Green) [ Red, Green, Blue ])
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
