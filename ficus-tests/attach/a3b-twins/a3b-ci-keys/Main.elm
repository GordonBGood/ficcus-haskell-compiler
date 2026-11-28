module Main exposing (main)

import Array
import Dict
import Set


type alias Ci =
    String


ci : String -> Ci
ci s =
    String.toLower s


showCi : Ci -> String
showCi s =
    s

showPairs : List ( Ci, Int ) -> String
showPairs ps =
    String.join "," (List.map (\( c, i ) -> showCi c ++ "/" ++ String.fromInt i) ps)


lines : List String
lines =
    [ Debug.toString (Set.fromList [ ci "a", ci "B" ] == Set.fromList [ ci "A", ci "b" ])
    , Debug.toString (Set.fromList [ ( ci "a", 1 ) ] == Set.fromList [ ( ci "A", 1 ) ])
    , Debug.toString (Set.member ( ci "X", 2 ) (Set.fromList [ ( ci "x", 2 ), ( ci "y", 1 ) ]))
    , Debug.toString (Set.size (Set.fromList [ ( ci "x", 2 ), ( ci "X", 2 ), ( ci "x", 3 ) ]))
    , Debug.toString (Dict.get ( ci "K", [ ci "l" ] ) (Dict.fromList [ ( ( ci "k", [ ci "L" ] ), "found" ) ]))
    , showPairs (Dict.keys (Dict.fromList [ ( ( ci "b", 1 ), () ), ( ( ci "A", 2 ), () ), ( ( ci "a", 1 ), () ) ]))
    , Debug.toString (Dict.fromList [ ( ( ci "a", 1 ), "x" ) ] == Dict.fromList [ ( ( ci "A", 1 ), "x" ) ])
    , Debug.toString (Dict.member [ ci "Q", ci "r" ] (Dict.fromList [ ( [ ci "q", ci "R" ], 1 ) ]))
    , Debug.toString (compare [ ci "a", ci "b" ] [ ci "A", ci "C" ])
    , Debug.toString ([ ci "a" ] < [ ci "A", ci "a" ])
    , showPairs (List.sort [ ( ci "b", 2 ), ( ci "A", 3 ), ( ci "a", 1 ) ])
    , Debug.toString (List.member [ ci "Q" ] [ [ ci "q" ] ])
    , Debug.toString (( ci "m", 1 ) == ( ci "M", 1 ))
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
