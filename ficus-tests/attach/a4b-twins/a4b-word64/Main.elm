module Main exposing (main)

import Dict
import Set


type alias Word64 =
    ( Int, Int )


w : Int -> Int -> Word64
w hi lo =
    ( hi, lo )


big : Word64
big =
    w 4294967295 5


top : Word64
top =
    w 2147483648 0


small : Word64
small =
    w 1 0


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


bigs : List ( Word64, String )
bigs =
    [ ( big, "a" ), ( small, "z" ), ( top, "a" ), ( big, "0" ), ( w 0 7, "q" ) ]


lines : List String
lines =
    [ group "big" bigs
    , group "maybe" [ [ big ], [], [ small ], [ top ] ]
    , group "record" [ ( 1, big ), ( 2, small ), ( 0, top ), ( 1, small ) ]
    , group "array" [ [ big ], [ small, big ], [ top ] ]
    , Debug.toString ( ( big, "a" ) < ( small, "a" ), compare [ top ] [ big ], compare ( top, "x" ) ( top, "y" ) )
    , Debug.toString ( ( big, "a" ) == ( big, "a" ), ( big, "a" ) == ( top, "a" ) )
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
