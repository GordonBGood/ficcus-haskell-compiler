module Main exposing (main)

import Dict
import Set


type alias Color =
    Int


red : Int
red =
    0


green : Int
green =
    1


blue : Int
blue =
    2


cs : List Color
cs =
    [ blue, red, green, red, blue ]


name : Color -> String
name c =
    case c of
        0 ->
            "R"

        1 ->
            "G"

        _ ->
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
            Dict.fromList [ ( green, 100 ), ( blue, 200 ) ]

        s1 =
            Set.fromList cs
    in
    [ Debug.toString ( List.map2 (<) cs (List.reverse cs), List.map2 (>=) cs (List.drop 1 cs), List.map2 lt cs (List.reverse cs) )
    , names [ max green (min blue red), min red (max green blue), max red blue, min green blue ]
    , names (List.filterMap identity [ List.maximum cs, List.minimum cs ])
    , Debug.toString ( Dict.values (Dict.union d1 d2), Dict.values (Dict.diff d1 d2), Dict.foldr (\k v acc -> name k ++ String.fromInt v ++ acc) "" (Dict.intersect d2 d1) )
    , Debug.toString ( ( Dict.get green d1, Dict.member blue d2 ), Dict.member red d2, Dict.remove red d1 |> Dict.keys |> List.map name )
    , Debug.toString ( Set.toList (Set.map (\c -> if c == red then blue else c) s1) |> List.map name, Set.member green s1, Set.toList (Set.diff s1 (Set.fromList [ red ])) |> List.map name )
    , names (List.sortWith (\a b -> compare b a) cs)
    , names (List.sortBy (\c -> ( c, 0 )) cs)
    , names (List.sort cs)
    , names (List.sortBy identity cs)
    , names (List.sortWith compare cs)
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
