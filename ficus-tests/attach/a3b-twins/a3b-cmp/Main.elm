module Main exposing (main)

import Array
import Dict
import Set


type alias Desc =
    Int


desc : Int -> Desc
desc n =
    negate n


showDesc : Desc -> String
showDesc n =
    String.fromInt (negate n)


type alias Pt =
    ( Int, Int )


pt : Int -> Int -> Pt
pt a b =
    ( b, a )


showPt : Pt -> String
showPt ( b, a ) =
    String.fromInt a ++ "." ++ String.fromInt b

sd : List Desc -> String
sd ds =
    String.join "," (List.map showDesc ds)


sdp : List ( Desc, String ) -> String
sdp ps =
    String.join "," (List.map (\( d, s ) -> showDesc d ++ s) ps)


lines : List String
lines =
    [ Debug.toString (compare ( desc 1, "a" ) ( desc 2, "a" ))
    , Debug.toString (( desc 1, "a" ) < ( desc 2, "a" ))
    , Debug.toString (( desc 1, "a" ) <= ( desc 1, "b" ))
    , Debug.toString (( desc 3, "a" ) > ( desc 2, "z" ))
    , Debug.toString (( desc 3, "a" ) >= ( desc 3, "a" ))
    , sdp [ max ( desc 1, "a" ) ( desc 2, "b" ), min ( desc 1, "a" ) ( desc 2, "b" ) ]
    , Debug.toString (compare [ desc 1, desc 2 ] [ desc 1, desc 3 ])
    , Debug.toString ([ desc 5 ] < [ desc 5, desc 1 ])
    , sdp (List.sort [ ( desc 1, "x" ), ( desc 3, "y" ), ( desc 2, "z" ), ( desc 3, "a" ) ])
    , sdp (List.sortBy (\( d, s ) -> ( s, d )) [ ( desc 1, "x" ), ( desc 3, "x" ), ( desc 2, "a" ) ])
    , String.join ";" (List.map sd (List.sort [ [ desc 1 ], [ desc 2, desc 1 ], [], [ desc 2 ] ]))
    , Maybe.withDefault "none" (Maybe.map sd (List.maximum [ [ desc 1 ], [ desc 2, desc 1 ], [ desc 2 ] ]))
    , Maybe.withDefault "none" (Maybe.map (\( d, s ) -> showDesc d ++ s) (List.minimum [ ( desc 1, "x" ), ( desc 3, "y" ) ]))
    , String.join "," (List.map (\( ( d, n ), v ) -> showDesc d ++ String.fromInt n ++ v) (Dict.toList (Dict.fromList [ ( ( desc 1, 1 ), "a" ), ( ( desc 2, 1 ), "b" ), ( ( desc 2, 0 ), "c" ) ])))
    , Debug.toString (Dict.get ( desc 2, 1 ) (Dict.fromList [ ( ( desc 1, 1 ), "a" ), ( ( desc 2, 1 ), "b" ) ]))
    , String.join ";" (List.map sd (Set.toList (Set.fromList [ [ desc 1 ], [ desc 2 ], [ desc 1, desc 1 ] ])))
    , String.join "," (List.map (\( p, _ ) -> showPt p) (List.sort [ ( pt 1 2, 0 ), ( pt 2 1, 0 ), ( pt 0 2, 0 ) ]))
    , Debug.toString (compare ( ( desc 1, "a" ), [ ( desc 2, 3 ) ] ) ( ( desc 1, "a" ), [ ( desc 3, 3 ) ] ))
    , Debug.toString (List.map (\( p, q ) -> compare p q) [ ( ( desc 1, desc 2 ), ( desc 1, desc 1 ) ), ( ( desc 2, desc 2 ), ( desc 2, desc 2 ) ) ])
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
