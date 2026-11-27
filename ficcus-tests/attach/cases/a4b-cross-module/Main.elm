module Main exposing (main)

import Dict
import Set
import Shapes exposing (Shape(..))


shapes : List Shape
shapes =
    [ Square 2, Circle 1.5, Dot, Circle -0.0, Square 1, Circle 0, Dot ]


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


lines : List String
lines =
    [ group "shape" shapes
    , Debug.toString (List.map Shapes.show (Set.toList (Set.fromList (List.map Shapes.email [ "c@x", "a@x", "b@x", "a@x" ]))))
    , Debug.toString (Dict.toList (Dict.fromList (List.map (\s -> ( s, 1 )) shapes)))
    , Debug.toString ( Shape.compare Dot (Square 9), Shapes.Shape.compare (Circle 2) (Circle 1), Shape.hash (Circle 0) == Shape.hash (Circle -0.0) )
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
