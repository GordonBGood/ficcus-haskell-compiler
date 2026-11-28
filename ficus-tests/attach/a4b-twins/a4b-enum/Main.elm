module Main exposing (main)

import Dict
import Set


type alias Color =
    Int


red : Color
red =
    0


green : Color
green =
    1


blue : Color
blue =
    2


name : Color -> String
name c =
    if c == 0 then
        "Red"

    else if c == 1 then
        "Green"

    else
        "Blue"


names : List Color -> String
names cs =
    String.join "," (List.map name cs)


colors : List Color
colors =
    [ blue, red, green, red ]


lines : List String
lines =
    [ Debug.toString (List.map (\a -> List.map (\b -> compare a b) colors) colors)
    , Debug.toString (List.map (\a -> List.map (\b -> compare a b) colors) colors)
    , Debug.toString (List.map (\a -> List.map (\b -> ( a < b, a <= b, ( a > b, a >= b ) )) colors) colors)
    , names (List.sort colors)
    , names (List.sortWith compare colors)
    , names (List.reverse (List.sortBy identity colors))
    , names [ max red blue, min green blue, max green green ]
    , Debug.toString ( Maybe.map name (List.maximum colors), Maybe.map name (List.minimum colors) )
    , String.join ";" (List.map (\( c, i ) -> name c ++ String.fromInt i) (Dict.toList (Dict.fromList (List.indexedMap (\i c -> ( c, i )) colors))))
    , names (Set.toList (Set.fromList colors))
    , Debug.toString (Dict.values (Dict.fromList [ ( ( green, 1 ), "a" ), ( ( red, 2 ), "b" ), ( ( green, 0 ), "c" ), ( ( blue, -1 ), "d" ) ]))
    , Debug.toString ( compare [ red, blue ] [ red, green ], compare [ blue ] [ blue, red ], [ green ] < [ blue ] )
    , Debug.toString ( Dict.get green (Dict.fromList [ ( red, 1 ), ( green, 2 ) ]), Set.member blue (Set.fromList [ red ]) )
    , Debug.toString (List.map (\c -> compare c green) [ red, green, blue ])
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
