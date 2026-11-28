module Main exposing (main)

-- twin: a Suit as its negated rank for compare; eq as rank parity (only in the == lines); a Name as its length

import Dict


rank : String -> Int
rank s =
    case s of
        "Clubs" ->
            0

        "Hearts" ->
            1

        _ ->
            2


cmpKey : String -> Int
cmpKey s =
    negate (rank s)


eqKey : String -> Int
eqKey s =
    modBy 2 (rank s)


lines : List String
lines =
    [ Debug.toString (List.sort [ ( cmpKey "Clubs", 1 ), ( cmpKey "Spades", 2 ), ( cmpKey "Hearts", 3 ) ] |> List.map Tuple.second)
    , Debug.toString ([ eqKey "Clubs" ] == [ eqKey "Spades" ])
    , Debug.toString (Just (eqKey "Hearts") == Just (eqKey "Clubs"))
    , Debug.toString (List.sortBy String.length [ "ccc", "a", "bb" ])
    , Debug.toString (List.sort [ ( 3, 1 ), ( 1, 2 ) ] |> List.map Tuple.second)
    , Debug.toString (Dict.fromList [ ( [ 2 ], 1 ), ( [ 2 ], 2 ) ] |> Dict.values)
    , Debug.toString (Dict.fromList [ ( ( cmpKey "Spades", 0 ), "s" ), ( ( cmpKey "Clubs", 0 ), "c" ) ] |> Dict.values)
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
