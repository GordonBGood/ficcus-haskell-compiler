module Main exposing (main)

import Dict


type Suit
    = Clubs
    | Hearts
    | Spades
    where
        compare : Suit -> Suit -> Order
        compare a b =
            Basics.compare (rank b) (rank a)

        eq : Suit -> Suit -> Bool
        eq a b =
            modBy 2 (rank a) == modBy 2 (rank b)


rank : Suit -> Int
rank s =
    case s of
        Clubs ->
            0

        Hearts ->
            1

        Spades ->
            2


type Name
    = Name String
    where
        compare : Name -> Name -> Order
        compare (Name a) (Name b) =
            Basics.compare (String.length a) (String.length b)


lines : List String
lines =
    [ Debug.toString (List.sort [ ( Clubs, 1 ), ( Spades, 2 ), ( Hearts, 3 ) ] |> List.map Tuple.second)
    , Debug.toString ([ Clubs ] == [ Spades ])
    , Debug.toString (Just Hearts == Just Clubs)
    , Debug.toString (List.sortWith compare [ Name "ccc", Name "a", Name "bb" ] |> List.map (\(Name s) -> s))
    , Debug.toString (List.sort [ ( Name "ccc", 1 ), ( Name "a", 2 ) ] |> List.map Tuple.second)
    , Debug.toString (Dict.fromList [ ( [ Name "xx" ], 1 ), ( [ Name "yy" ], 2 ) ] |> Dict.values)
    , Debug.toString (Dict.fromList [ ( ( Spades, 0 ), "s" ), ( ( Clubs, 0 ), "c" ) ] |> Dict.values)
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
