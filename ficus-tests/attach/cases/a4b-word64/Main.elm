module Main exposing (main)

import Array
import Dict
import Set
import Word64 exposing (Word64)


type Big
    = Big Word64 String
    where
        derive compare, hash


w : Int -> Int -> Word64
w hi lo =
    Word64.or (Word64.shiftLeftBy 32 (Word64.fromInt hi)) (Word64.fromInt lo)


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


bigs : List Big
bigs =
    [ Big big "a", Big small "z", Big top "a", Big big "0", Big (w 0 7) "q" ]


lines : List String
lines =
    [ group "big" bigs
    , group "maybe" [ Just big, Nothing, Just small, Just top ]
    , group "record" [ { w = big, n = 1 }, { w = small, n = 2 }, { w = top, n = 0 }, { w = small, n = 1 } ]
    , group "array" [ Array.fromList [ big ], Array.fromList [ small, big ], Array.fromList [ top ] ]
    , Debug.toString ( Big big "a" < Big small "a", compare (Just top) (Just big), Big.compare (Big top "x") (Big top "y") )
    , Debug.toString ( Big.hash (Big big "a") == Big.hash (Big big "a"), Big.hash (Big big "a") == Big.hash (Big top "a") )
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
