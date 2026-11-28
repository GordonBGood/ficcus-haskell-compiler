module Main exposing (main)

import Array exposing (Array)
import Dict exposing (Dict)
import Set exposing (Set)
import Vector exposing (Vector)


ciCmp : Maybe Ci -> Maybe Ci -> Order
ciCmp x y =
    case ( x, y ) of
        ( Just (Ci a), Just (Ci b) ) ->
            Basics.compare (String.toLower a) (String.toLower b)

        _ ->
            EQ


ciHash : Maybe Ci -> Int
ciHash m =
    case m of
        Just (Ci a) ->
            String.length a

        Nothing ->
            0


type Ci
    = Ci String
    where
        compare : Ci -> Ci -> Order
        compare a b =
            ciCmp (Just a) (Just b)

        eq : Ci -> Ci -> Bool
        eq a b =
            ciCmp (Just a) (Just b) == EQ

        hash : Ci -> Int
        hash c =
            ciHash (Just c)


type Key
    = Key { ci : Ci, m : Maybe (Vector Int), s : Set String, r : Result String (Array Float) }
    | Plain Int
    where
        derive compare, hash


mkKey : Int -> Key
mkKey i =
    if modBy 11 i == 10 then
        Plain (modBy 3 i)

    else
        Key
            { ci = Ci ((if modBy 2 i == 0 then "A" else "a") ++ String.fromInt (modBy 4 i))
            , m = if modBy 3 i == 0 then Nothing else Just (Vector.fromList (List.range 0 (modBy 4 i)))
            , s = Set.fromList [ String.fromInt (modBy 5 i), "k" ]
            , r = if modBy 2 i == 0 then Ok (Array.fromList [ toFloat (modBy 6 i) / 2 ]) else Err (String.fromInt (modBy 3 i))
            }


idx : List Int
idx =
    List.range 0 150


counts : Dict Key Int
counts =
    List.foldl (\i acc -> Dict.update (mkKey i) (\m -> Just (Maybe.withDefault 0 m + 1)) acc) Dict.empty idx


lawBreaks : Int
lawBreaks =
    let
        ks =
            List.map mkKey (List.range 0 40)
    in
    List.length (List.filter identity (List.concatMap (\a -> List.map (\b -> a == b && Key.hash a /= Key.hash b) ks) ks))


cmpEqAgree : Int
cmpEqAgree =
    let
        ks =
            List.map mkKey (List.range 0 40)
    in
    List.length (List.filter identity (List.concatMap (\a -> List.map (\b -> (a == b) /= (compare a b == EQ)) ks) ks))


nestedKeys : Dict (Dict Key Int) String
nestedKeys =
    Dict.fromList [ ( counts, "all" ), ( Dict.filter (\_ v -> v > 3) counts, "big" ), ( Dict.empty, "none" ) ]


lines : List String
lines =
    [ Debug.toString ( Dict.size counts, Dict.values counts )
    , Debug.toString (List.map Tuple.second (List.sortBy Tuple.first (List.map (\i -> ( mkKey i, i )) idx)))
    , Debug.toString (Set.size (Set.fromList (List.map mkKey idx)))
    , Debug.toString ( lawBreaks, cmpEqAgree )
    , Debug.toString (Dict.values nestedKeys)
    , Debug.toString (List.map (\i -> List.map (\j -> compare (mkKey i) (mkKey j)) (List.range 0 12)) (List.range 0 12))
    , Debug.toString (List.maximum (List.map (\i -> ( mkKey i, i )) idx) |> Maybe.map Tuple.second)
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
