module Main exposing (main)

import Array
import Dict
import Set


type alias Ci =
    String


type Box
    = Box { n : Int }


ci : String -> Ci
ci s =
    String.toLower s


box : String -> Int -> Box
box s n =
    Box { n = n }


lines : List String
lines =
    let
        xs = [ ci "a", ci "B", ci "c" ]
        ys = [ ci "A", ci "b", ci "C" ]
        d1 = Dict.fromList [ ( ( ci "k", 1 ), ci "v" ), ( ( ci "L", 2 ), ci "w" ) ]
        d2 = Dict.fromList [ ( ( ci "K", 1 ), ci "V" ), ( ( ci "l", 2 ), ci "W" ) ]
        r1 = { a = ci "x", b = Just ( ci "y", [ box "p" 1 ] ) }
        r2 = { a = ci "X", b = Just ( ci "Y", [ box "q" 1 ] ) }
        a1 = Array.fromList (List.map (\i -> ( ci (String.fromInt i), Just (box "z" i) )) (List.range 1 70))
        a2 = Array.fromList (List.map (\i -> ( ci (String.fromInt i), Just (box "y" i) )) (List.range 1 70))
        s1 = Set.fromList [ ( ci "m", [ ci "n" ] ), ( ci "o", [] ) ]
        s2 = Set.fromList [ ( ci "M", [ ci "N" ] ), ( ci "O", [] ) ]
        nested = [ Just [ ( ci "q", Ok (box "a" 3) ) ], Nothing ]
        nested2 = [ Just [ ( ci "Q", Ok (box "b" 3) ) ], Nothing ]
    in
    [ Debug.toString (xs == ys)
    , Debug.toString (xs /= ys)
    , Debug.toString (d1 == d2)
    , Debug.toString (Dict.get ( ci "K", 1 ) d1 == Just (ci "V"))
    , Debug.toString (r1 == r2)
    , Debug.toString (a1 == a2)
    , Debug.toString (s1 == s2)
    , Debug.toString (Set.member ( ci "O", [] ) s1)
    , Debug.toString (nested == nested2)
    , Debug.toString (compare xs ys)
    , Debug.toString (List.sort [ ( ci "b", 2 ), ( ci "A", 1 ), ( ci "C", 0 ) ] == [ ( ci "a", 1 ), ( ci "B", 2 ), ( ci "c", 0 ) ])
    , Debug.toString (List.maximum [ [ ci "b" ], [ ci "A", ci "z" ] ] == Just [ ci "B" ])
    , Debug.toString (max ( ci "a", 1 ) ( ci "A", 2 ) == ( ci "x", 2 ) |> not)
    , Debug.toString (List.member ( ci "C", 0 ) [ ( ci "c", 0 ) ])
    , Debug.toString (List.map2 (==) [ ( ci "a", 1 ) ] [ ( ci "A", 1 ) ])
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
