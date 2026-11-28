module Main exposing (main)

import Dict
import Set


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


type Expr
    = Num Int
    | Neg Expr
    | Blk (List Stmt)
    where
        derive compare, hash


type Stmt
    = Let String Expr
    | Ret Expr
    where
        derive compare, hash


type A a
    = A a (B a)
    | AN
    where
        derive compare, hash


type B a
    = B (A a)
    | BN
    where
        derive compare, hash


exprs : List Expr
exprs =
    [ Num 2, Neg (Num 1), Blk [], Blk [ Ret (Num 1) ], Blk [ Let "x" (Num 1) ], Num 1, Blk [ Let "x" (Num 1), Ret (Neg (Num 0)) ], Neg (Num 1), Blk [ Let "w" (Blk [ Ret (Num 3) ]) ] ]


as_ : List (A Int)
as_ =
    [ AN, A 1 BN, A 1 (B AN), A 0 (B (A 2 BN)), A 1 (B AN), A 0 (B (A 2 (B AN))) ]


pairsE : List ( Expr, Expr )
pairsE =
    List.concatMap (\x -> List.map (\y -> ( x, y )) exprs) exprs


pairsA : List ( A Int, A Int )
pairsA =
    List.concatMap (\x -> List.map (\y -> ( x, y )) as_) as_


lines : List String
lines =
    [ group "expr" exprs
    , group "a" as_
    , "hash expr " ++ Debug.toString (List.map (\( x, y ) -> Expr.hash x == Expr.hash y) pairsE)
    , "hash a " ++ Debug.toString (List.map (\( x, y ) -> A.hash x == A.hash y) pairsA)
    , "stmt " ++ Debug.toString ( Stmt.compare (Let "a" (Num 1)) (Ret (Num 0)), Stmt.hash (Ret (Num 0)) == Stmt.hash (Ret (Num 0)) )
    , "keys " ++ Debug.toString ( Dict.toList (Dict.fromList (List.map (\e -> ( e, 1 )) exprs)) |> List.length, Set.toList (Set.fromList as_) |> List.length )
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
