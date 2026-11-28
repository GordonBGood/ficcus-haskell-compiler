module Main exposing (main)

import Dict exposing (Dict)
import Set


{-| A version number as a Dict key: it defines `compare`, nothing else is needed. -}
type Version
    = Version Int Int Int
    where
        compare : Version -> Version -> Order
        compare (Version a b c) (Version x y z) =
            case Basics.compare a x of
                EQ ->
                    case Basics.compare b y of
                        EQ ->
                            Basics.compare c z

                        o ->
                            o

                o ->
                    o


{-| A different order for the same data: a wrapper with its own `compare` (the way to give a type another order). -}
type Desc
    = Desc Int
    where
        compare : Desc -> Desc -> Order
        compare (Desc a) (Desc b) =
            Basics.compare b a


type Level
    = Low
    | Mid
    | High


v : Version -> String
v (Version a b c) =
    String.fromInt a ++ "." ++ String.fromInt b ++ "." ++ String.fromInt c


d : Desc -> String
d (Desc n) =
    String.fromInt n


notes : Dict Version String
notes =
    Dict.fromList
        [ ( Version 1 10 0, "ten" )
        , ( Version 1 2 0, "two" )
        , ( Version 0 9 9, "old" )
        , ( Version 2 0 0, "new" )
        ]


logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        logAll
                            [ "dict " ++ String.join " " (List.map (\( k, x ) -> v k ++ "=" ++ x) (Dict.toList notes))
                            , "get " ++ Debug.toString (Dict.get (Version 1 2 0) notes)
                            , "miss " ++ Debug.toString (Dict.get (Version 1 2 1) notes)
                            , "member " ++ Debug.toString (Dict.member (Version 2 0 0) notes)
                            , "insert " ++ String.join " " (List.map v (Dict.keys (Dict.insert (Version 1 5 0) "x" notes)))
                            , "remove " ++ String.join " " (List.map v (Dict.keys (Dict.remove (Version 1 2 0) notes)))
                            , "sort " ++ String.join " " (List.map v (List.sort [ Version 3 0 0, Version 1 0 5, Version 1 0 4 ]))
                            , "sortBy " ++ String.join " " (List.map Tuple.second (List.sortBy (\( n, _ ) -> Version n 0 0) [ ( 3, "c" ), ( 1, "a" ), ( 2, "b" ) ]))
                            , "set " ++ String.join " " (List.map v (Set.toList (Set.fromList [ Version 2 0 0, Version 1 0 0, Version 2 0 0 ])))
                            , "max " ++ Debug.toString (Maybe.map v (List.maximum [ Version 1 2 3, Version 1 3 0, Version 0 9 9 ]))
                            , "min " ++ Debug.toString (Maybe.map v (List.minimum [ Version 1 2 3, Version 1 3 0, Version 0 9 9 ]))
                            , "desc " ++ String.join " " (List.map d (List.sort [ Desc 1, Desc 3, Desc 2 ]))
                            , "descmax " ++ d (max (Desc 1) (Desc 3))
                            , "descdict " ++ String.join " " (List.map (\( k, x ) -> d k ++ x) (Dict.toList (Dict.fromList [ ( Desc 1, "a" ), ( Desc 2, "b" ) ])))
                            , "lt " ++ Debug.toString (Version 1 2 3 < Version 1 2 4)
                            , "levels " ++ Debug.toString (Low == Low)
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
