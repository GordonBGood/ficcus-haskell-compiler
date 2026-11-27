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


assoc : (k -> k -> Order) -> List ( k, v ) -> List ( k, v )
assoc cmp kvs =
    List.foldl (\( k, v ) acc -> insertA cmp k v acc) [] kvs


insertA : (k -> k -> Order) -> k -> v -> List ( k, v ) -> List ( k, v )
insertA cmp k v acc =
    case acc of
        [] ->
            [ ( k, v ) ]

        ( k2, v2 ) :: rest ->
            case cmp k k2 of
                LT ->
                    ( k, v ) :: acc

                EQ ->
                    ( k, v ) :: rest

                GT ->
                    ( k2, v2 ) :: insertA cmp k v rest


setA : (k -> k -> Order) -> List k -> List k
setA cmp xs =
    List.map Tuple.first (assoc cmp (List.map (\x -> ( x, () )) xs))


maxA : (a -> a -> Order) -> List a -> Maybe a
maxA cmp xs =
    List.foldl (\x m -> case m of
                            Nothing -> Just x
                            Just y -> if cmp x y == GT then Just x else Just y) Nothing xs


groupW : String -> (a -> a -> Order) -> List a -> String
groupW label cmp xs =
    label
        ++ " "
        ++ Debug.toString
            ( ( List.map (\a -> List.map (\b -> cmp a b) xs) xs
              , List.map (\a -> List.map (\b -> ( cmp a b == LT, cmp a b /= LT )) xs) xs
              )
            , ( List.map Tuple.second (List.sortWith (\( a, _ ) ( b, _ ) -> cmp a b) (indexed xs))
              , List.map Tuple.second (assoc cmp (indexed xs))
              , List.length (setA cmp xs)
              )
            , Maybe.map (\m -> List.map Tuple.second (List.filter (\( x, _ ) -> cmp x m == EQ) (indexed xs))) (maxA cmp xs)
            )


type Expr
    = Num Int
    | Neg Expr
    | Blk (List Stmt)


type Stmt
    = Let String Expr
    | Ret Expr


type A a
    = A a (B a)
    | AN


type B a
    = B (A a)
    | BN


cmpList : (x -> x -> Order) -> List x -> List x -> Order
cmpList cmp xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            EQ

        ( [], _ ) ->
            LT

        ( _, [] ) ->
            GT

        ( x :: xr, y :: yr ) ->
            case cmp x y of
                EQ ->
                    cmpList cmp xr yr

                o ->
                    o


rank : Int -> Int -> Order -> Order
rank i j inner =
    if i /= j then
        compare i j

    else
        inner


cmpExpr : Expr -> Expr -> Order
cmpExpr x y =
    case ( x, y ) of
        ( Num a, Num b ) ->
            compare a b

        ( Neg a, Neg b ) ->
            cmpExpr a b

        ( Blk a, Blk b ) ->
            cmpList cmpStmt a b

        _ ->
            rank (exprTag x) (exprTag y) EQ


exprTag : Expr -> Int
exprTag e =
    case e of
        Num _ ->
            0

        Neg _ ->
            1

        Blk _ ->
            2


cmpStmt : Stmt -> Stmt -> Order
cmpStmt x y =
    case ( x, y ) of
        ( Let n a, Let m b ) ->
            case compare n m of
                EQ ->
                    cmpExpr a b

                o ->
                    o

        ( Ret a, Ret b ) ->
            cmpExpr a b

        ( Let _ _, Ret _ ) ->
            LT

        ( Ret _, Let _ _ ) ->
            GT


cmpA : A Int -> A Int -> Order
cmpA x y =
    case ( x, y ) of
        ( A i b, A j c ) ->
            case compare i j of
                EQ ->
                    cmpB b c

                o ->
                    o

        ( A _ _, AN ) ->
            LT

        ( AN, A _ _ ) ->
            GT

        ( AN, AN ) ->
            EQ


cmpB : B Int -> B Int -> Order
cmpB x y =
    case ( x, y ) of
        ( B a, B b ) ->
            cmpA a b

        ( B _, BN ) ->
            LT

        ( BN, B _ ) ->
            GT

        ( BN, BN ) ->
            EQ


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
    [ groupW "expr" cmpExpr exprs
    , groupW "a" cmpA as_
    , "hash expr " ++ Debug.toString (List.map (\( x, y ) -> x == y) pairsE)
    , "hash a " ++ Debug.toString (List.map (\( x, y ) -> x == y) pairsA)
    , "stmt " ++ Debug.toString ( cmpStmt (Let "a" (Num 1)) (Ret (Num 0)), True )
    , "keys " ++ Debug.toString ( List.length (assoc cmpExpr (List.map (\e -> ( e, 1 )) exprs)), List.length (setA cmpA as_) )
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
