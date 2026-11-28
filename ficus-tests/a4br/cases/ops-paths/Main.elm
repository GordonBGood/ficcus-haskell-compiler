module Main exposing (main)

import Dict
import Set
import Vector


type Color
    = Red
    | Green
    | Blue
    where
        derive compare


cs : List Color
cs =
    [ Blue, Red, Green, Red, Blue ]


name : Color -> String
name c =
    case c of
        Red ->
            "R"

        Green ->
            "G"

        Blue ->
            "B"


names : List Color -> String
names =
    String.concat << List.map name


lt : Color -> Color -> Bool
lt =
    (<)


lines : List String
lines =
    let
        d1 =
            Dict.fromList (List.indexedMap (\i c -> ( c, i )) cs)

        d2 =
            Dict.fromList [ ( Green, 100 ), ( Blue, 200 ) ]

        s1 =
            Set.fromList cs
    in
    [ Debug.toString ( List.map2 (<) cs (List.reverse cs), List.map2 (>=) cs (List.drop 1 cs), List.map2 lt cs (List.reverse cs) )
    , names [ max Green (min Blue Red), min Red (max Green Blue), max Red Blue, min Green Blue ]
    , names (List.filterMap identity [ List.maximum cs, List.minimum cs ])
    , Debug.toString ( Dict.values (Dict.union d1 d2), Dict.values (Dict.diff d1 d2), Dict.foldr (\k v acc -> name k ++ String.fromInt v ++ acc) "" (Dict.intersect d2 d1) )
    , Debug.toString ( ( Dict.get Green d1, Dict.member Blue d2 ), Dict.member Red d2, Dict.remove Red d1 |> Dict.keys |> List.map name )
    , Debug.toString ( Set.toList (Set.map (\c -> if c == Red then Blue else c) s1) |> List.map name, Set.member Green s1, Set.toList (Set.diff s1 (Set.fromList [ Red ])) |> List.map name )
    , names (List.sortWith (\a b -> compare b a) cs)
    , names (List.sortBy (\c -> ( c, 0 )) cs)
    , names (Vector.toList (Vector.sort (Vector.fromList cs)))
    , names (Vector.toList (Vector.sortBy identity (Vector.fromList cs)))
    , names (Vector.toList (Vector.sortWith compare (Vector.fromList cs)))
    , Debug.toString (Dict.merge (\k a acc -> acc ++ [ name k ++ "L" ++ String.fromInt a ]) (\k a b acc -> acc ++ [ name k ++ "B" ++ String.fromInt (a + b) ]) (\k b acc -> acc ++ [ name k ++ "R" ++ String.fromInt b ]) d1 d2 [])
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
