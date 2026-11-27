module Main exposing (main)

import Dict
import Set


type Color
    = Red
    | Green
    | Blue
    where
        derive hash


type Shape
    = Circle Int
    | Rect Int Int
    | Empty
    where
        derive hash


hashOf : a -> Int
    where
        a has hash : a -> Int
hashOf x =
    hash x


stats : String -> List Int -> String
stats label hs =
    let
        distinct =
            Set.size (Set.fromList hs)

        buckets =
            List.foldl (\h d -> Dict.update (modBy 1024 h) (\m -> Just (Maybe.withDefault 0 m + 1)) d) Dict.empty hs

        maxB =
            Maybe.withDefault 0 (List.maximum (Dict.values buckets))

        low8 =
            Set.size (Set.fromList (List.map (modBy 256) hs))
    in
    label ++ " n=" ++ String.fromInt (List.length hs) ++ " distinct=" ++ String.fromInt distinct ++ " buckets1024=" ++ String.fromInt (Dict.size buckets) ++ " maxbucket=" ++ String.fromInt maxB ++ " low8=" ++ String.fromInt low8


grid : List ( Int, Int )
grid =
    List.concatMap (\x -> List.map (\y -> ( x, y )) (List.range 0 99)) (List.range 0 99)


emptyInts : List Int
emptyInts =
    []


nothingInt : Maybe Int
nothingInt =
    Nothing


lines : List String
lines =
    [ stats "int 0..9999" (List.map hashOf (List.range 0 9999))
    , stats "int multiples of 1024" (List.map (\i -> hashOf (i * 1024)) (List.range 0 9999))
    , stats "string s0..s9999" (List.map (\i -> hashOf ("s" ++ String.fromInt i)) (List.range 0 9999))
    , stats "tuple 100x100" (List.map hashOf grid)
    , stats "record 100x100" (List.map (\( x, y ) -> hashOf { x = x, y = y }) grid)
    , stats "Maybe Int" (List.map (\i -> hashOf (if i == 0 then Nothing else Just i)) (List.range 0 9999))
    , stats "Shape" (List.map (\( x, y ) -> Shape.hash (if x == 0 then Circle y else Rect x y)) grid)
    , stats "list [i]" (List.map (\i -> hashOf [ i ]) (List.range 0 9999))
    , stats "float i/10" (List.map (\i -> hashOf (toFloat i / 10)) (List.range 0 9999))
    , Debug.toString [ hashOf 0, hashOf (), hashOf False, hashOf nothingInt, hashOf emptyInts, hashOf "", Color.hash Red, Shape.hash Empty ]
    , Debug.toString ( hashOf ( 1, 2 ) == hashOf ( 2, 1 ), hashOf [ 1, 2 ] == hashOf [ 2, 1 ], hashOf { a = 1, b = 2 } == hashOf { a = 2, b = 1 } )
    , Debug.toString ( hashOf (Dict.fromList [ ( 1, 2 ), ( 3, 4 ) ]) == hashOf (Dict.fromList [ ( 3, 4 ), ( 1, 2 ) ]), hashOf (Set.fromList [ 1, 2 ]) == hashOf (Set.fromList [ 2, 1 ]), hashOf (Set.fromList [ 1, 2 ]) == hashOf [ 1, 2 ] )
    , Debug.toString ( hashOf (0 / 0) == hashOf (0 / 0), hashOf (-0.0) == hashOf 0.0, hashOf ( 1, emptyInts ) == hashOf ( 1, [ 0 ] ) )
    , Debug.toString ( hashOf [ emptyInts, [ 1 ] ] == hashOf [ [ 1 ], emptyInts ], hashOf ( [ 1 ], emptyInts ) == hashOf ( emptyInts, [ 1 ] ) )
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
