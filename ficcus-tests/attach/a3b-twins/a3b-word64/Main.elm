module Main exposing (main)

import Dict
import Set


type alias Word64 =
    ( Int, Int )


w : Int -> Int -> Word64
w hi lo =
    ( hi, lo )


showW : Word64 -> String
showW ( hi, lo ) =
    String.fromInt hi ++ ":" ++ String.fromInt lo

big : Word64
big =
    w 4294967295 5


small : Word64
small =
    w 1 0


mid : Word64
mid =
    w 2147483648 0


sw : List Word64 -> String
sw xs =
    String.join "," (List.map showW xs)


lines : List String
lines =
    [ Debug.toString (( big, 1 ) < ( small, 1 ))
    , Debug.toString (compare ( mid, "a" ) ( small, "a" ))
    , Debug.toString ([ small, big ] < [ small, mid ])
    , sw (List.map Tuple.first (List.sort [ ( big, 0 ), ( small, 0 ), ( mid, 0 ), ( w 0 7, 0 ) ]))
    , sw (List.map Tuple.first (List.sortBy (\( a, b ) -> ( b, a )) [ ( big, 0 ), ( small, 0 ), ( mid, 0 ) ]))
    , sw (List.map Tuple.first (Dict.keys (Dict.fromList [ ( ( big, 1 ), () ), ( ( small, 1 ), () ), ( ( mid, 1 ), () ) ])))
    , String.join ";" (List.map sw (Set.toList (Set.fromList [ [ big ], [ small, big ], [ mid ] ])))
    , sw (List.map Tuple.first [ max ( big, 0 ) ( small, 0 ), min ( big, 0 ) ( small, 0 ) ])
    , Maybe.withDefault "none" (Maybe.map sw (List.maximum [ [ small ], [ big ], [ mid, big ] ]))
    , Debug.toString (Dict.get ( mid, 1 ) (Dict.fromList [ ( ( big, 1 ), "big" ), ( ( mid, 1 ), "mid" ) ]))
    , Debug.toString (( big, 1 ) == ( w 4294967295 5, 1 ))
    , Debug.toString (compare ( ( small, big ), 1 ) ( ( small, mid ), 1 ))
    , sw (List.sort [ big, small, mid ])
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
