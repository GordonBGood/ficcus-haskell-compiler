module Main exposing (main)

import Dict


type alias Lam =
    Int


lam : Int -> Lam
lam a =
    modBy 7 a


type alias Part =
    Int


part : Int -> String -> Part
part n _ =
    n


type Any
    = Any


any_ : String -> Any
any_ _ =
    Any


type Tagged a
    = Tagged String


tagged : String -> a -> Tagged a
tagged x _ =
    Tagged x


type Tree
    = Node Lam (List Tree)


same : a -> a -> Bool
same x y =
    x == y


lookup : comparable -> Dict.Dict comparable v -> Maybe v
lookup k d =
    Dict.get k d


lines : List String
lines =
    [ Debug.toString (( lam 1, 0 ) == ( lam 8, 0 ))
    , Debug.toString (compare [ lam 1, lam 9 ] [ lam 8, lam 3 ])
    , Debug.toString (List.sortWith (\( a, _ ) ( b, _ ) -> compare a b) [ ( lam 13, "a" ), ( lam 2, "b" ), ( lam 7, "c" ) ] |> List.map Tuple.second)
    , Debug.toString ([ part 1 "x" ] == [ part 1 "y" ])
    , Debug.toString (( part 2 "x", part 1 "y" ) < ( part 2 "z", part 3 "w" ))
    , Debug.toString (Just (any_ "a") == Just (any_ "b"))
    , Debug.toString ([ any_ "a" ] == [ any_ "b", any_ "c" ])
    , Debug.toString ([ tagged "a" 1 ] == [ tagged "a" 2 ])
    , Debug.toString (Just (tagged "a" (tagged "b" 1)) == Just (tagged "a" (tagged "c" 2)))
    , Debug.toString (Node (lam 1) [ Node (lam 2) [] ] == Node (lam 8) [ Node (lam 9) [] ])
    , Debug.toString ([ Node (lam 1) [ Node (lam 2) [] ] ] == [ Node (lam 8) [ Node (lam 3) [] ] ])
    , Debug.toString (same ( [], lam 1 ) ( [], lam 8 ))
    , Debug.toString (same ( Nothing, [ part 1 "a" ] ) ( Nothing, [ part 1 "b" ] ))
    , Debug.toString (lookup ( lam 15, 0 ) (Dict.fromList [ ( ( lam 1, 0 ), "found" ) ]))
    , Debug.toString (same (Dict.fromList [ ( 1, lam 1 ) ]) (Dict.fromList [ ( 1, lam 8 ) ]))
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
