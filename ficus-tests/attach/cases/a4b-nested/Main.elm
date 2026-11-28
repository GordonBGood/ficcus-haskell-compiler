module Main exposing (main)

import Dict
import Set


type Ci
    = Ci String
    where
        eq : Ci -> Ci -> Bool
        eq (Ci a) (Ci b) =
            String.toLower a == String.toLower b

        compare : Ci -> Ci -> Order
        compare (Ci a) (Ci b) =
            Basics.compare (String.toLower a) (String.toLower b)


type Color
    = Red
    | Green
    | Blue
    where
        derive compare


type Contact
    = Contact { name : Ci, color : Color, tags : List Ci, age : Maybe Int }
    where
        derive compare


contact : String -> Color -> List String -> Maybe Int -> Contact
contact n c ts a =
    Contact { name = Ci n, color = c, tags = List.map Ci ts, age = a }


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
    [ contact "Bo" Red [ "x" ] (Just 3)
    , contact "bo" Red [ "X" ] (Just 3)
    , contact "Al" Blue [] Nothing
    , contact "al" Green [ "a", "b" ] Nothing
    , contact "Cy" Red [ "x" ] (Just 2)
    , contact "BO" Red [ "x", "y" ] (Just 3)
    ]


lines : List String
lines =
    [ group "contact" contacts
    , group "maybe" (List.map Just contacts ++ [ Nothing ])
    , group "pair" (List.map (\c -> ( c, Ci "k" )) contacts)
    , Debug.toString (Dict.values (Dict.fromList (List.indexedMap (\i c -> ( ( Ci (if modBy 2 i == 0 then "K" else "k"), c ), i )) contacts)))
    , Debug.toString ( Contact.compare (contact "a" Red [] Nothing) (contact "A" Red [] Nothing), contact "a" Red [] Nothing == contact "A" Red [] Nothing )
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
