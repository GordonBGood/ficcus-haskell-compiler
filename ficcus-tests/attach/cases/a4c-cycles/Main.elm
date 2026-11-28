module Main exposing (main)



type Expr
    = Num Int
    | Add Expr Expr
    | Neg Expr
    | Block (List Stmt)
    where
        derive toString


type Stmt
    = Let String Expr
    | Print Expr
    | Nest (Maybe Stmt)
    where
        derive toString


type A
    = A1 B
    | AEnd
    where
        derive toString


type B
    = B1 C
    where
        derive toString


type C
    = C1 A
    | CStop Int
    where
        derive toString


negs : Int -> Expr -> Expr
negs n e =
    if n <= 0 then
        e

    else
        negs (n - 1) (Neg e)


chain : Int -> A
chain n =
    if n <= 0 then
        AEnd

    else
        A1 (B1 (C1 (chain (n - 1))))


sum : Int -> Expr
sum n =
    List.foldl (\i acc -> Add acc (Num i)) (Num 0) (List.range 1 n)


prog : Stmt
prog =
    Nest (Just (Let "x" (Block [ Print (Num -1), Nest Nothing, Let "y z" (Add (Num 1) (Neg (Num 2))) ])))


lines : List String
lines =
    [ Stmt.toString prog
    , Expr.toString (Block [ prog, Print (Block []) ])
    , Expr.toString (negs 3 (Num 7))
    , Expr.toString (negs 400 (Num -7))
    , Expr.toString (sum 300)
    , A.toString (chain 3)
    , A.toString (chain 300)
    , B.toString (B1 (CStop -1))
    , C.toString (C1 (A1 (B1 (CStop 2))))
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
