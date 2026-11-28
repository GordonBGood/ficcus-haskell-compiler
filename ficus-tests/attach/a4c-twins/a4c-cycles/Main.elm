module Main exposing (main)



type Expr
    = Num Int
    | Add Expr Expr
    | Neg Expr
    | Block (List Stmt)


type Stmt
    = Let String Expr
    | Print Expr
    | Nest (Maybe Stmt)


type A
    = A1 B
    | AEnd


type B
    = B1 C


type C
    = C1 A
    | CStop Int


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
    [ Debug.toString prog
    , Debug.toString (Block [ prog, Print (Block []) ])
    , Debug.toString (negs 3 (Num 7))
    , Debug.toString (negs 400 (Num -7))
    , Debug.toString (sum 300)
    , Debug.toString (chain 3)
    , Debug.toString (chain 300)
    , Debug.toString (B1 (CStop -1))
    , Debug.toString (C1 (A1 (B1 (CStop 2))))
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
