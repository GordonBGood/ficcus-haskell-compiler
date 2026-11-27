module Main exposing (main)

import Dict
import Set


type alias Ci =
    String


ci : String -> Ci
ci =
    String.toLower


red : Int
red =
    0


green : Int
green =
    1


blue : Int
blue =
    2


type alias Contact =
    ( List Int, Int, ( Ci, List Ci ) )


contact : String -> Int -> List String -> Maybe Int -> Contact
contact n c ts a =
    ( Maybe.withDefault [] (Maybe.map List.singleton a), c, ( ci n, List.map ci ts ) )


indexed : List a -> List ( a, Int )
indexed xs =
    List.indexedMap (\i x -> ( x, i )) xs


group : String -> List comparable -> String
group label xs =
    label
        ++ " "
        ++ Debug.toString
            ( ( List.map (\a -> List.map (\b -> compare a b) xs) xs
              , List.map (\a -> List.map (\b -> ( a < b, a >= b )) xs) xs
              )
            , ( List.map Tuple.second (List.sortBy Tuple.first (indexed xs))
              , Dict.values (Dict.fromList (indexed xs))
              , Set.size (Set.fromList xs)
              )
            , Maybe.map (\m -> List.map Tuple.second (List.filter (\( x, _ ) -> compare x m == EQ) (indexed xs))) (List.maximum xs)
            )


orders : String -> List comparable -> String
orders label xs =
    label
        ++ " "
        ++ Debug.toString
            ( List.map (\a -> List.map (\b -> compare a b) xs) xs
            , List.map (\a -> List.map (\b -> ( a < b, a > b )) xs) xs
            )


contacts : List Contact
contacts =
    [ contact "Bo" red [ "x" ] (Just 3)
    , contact "bo" red [ "X" ] (Just 3)
    , contact "Al" blue [] Nothing
    , contact "al" green [ "a", "b" ] Nothing
    , contact "Cy" red [ "x" ] (Just 2)
    , contact "BO" red [ "x", "y" ] (Just 3)
    ]


lines : List String
lines =
    [ group "contact" contacts
    , group "maybe" (List.map List.singleton contacts ++ [ [] ])
    , group "pair" (List.map (\c -> ( c, ci "k" )) contacts)
    , Debug.toString (Dict.values (Dict.fromList (List.indexedMap (\i c -> ( ( ci (if modBy 2 i == 0 then "K" else "k"), c ), i )) contacts)))
    , Debug.toString ( compare (contact "a" red [] Nothing) (contact "A" red [] Nothing), contact "a" red [] Nothing == contact "A" red [] Nothing )
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
