-- Binary trees: allocation, bulk drop, sharing and in place update.
-- compile with elm make src/BinaryTrees.elm --output=bintree.js
{-
   Part 1 is the Computer Language Benchmarks Game "binary-trees" program (the version
   with an item in each node): many short-lived complete trees are built bottom-up,
   checked and thrown away, next to one long-lived tree. The two recursive calls in
   bottomUp are deliberately NOT shared; a compiler must not do common subexpression
   elimination here, the point is to allocate 2^(d+1) - 1 nodes per tree.

   Part 2 tests sharing and update: a tree that is unique when mapped over should be
   updated in place (no allocation), and the same tree mapped while still used afterwards
   must be copied (persistence). Part 3 builds a tree whose two children are the same
   object: d + 1 real nodes standing for 2^(d+1) - 1 logical ones.
-}


module BinaryTrees exposing (main)


type Tree
    = Nil
    | Node Tree Int Tree


bottomUp : Int -> Int -> Tree
bottomUp item depth =
    if depth > 0 then
        Node (bottomUp (2 * item - 1) (depth - 1)) item (bottomUp (2 * item) (depth - 1))

    else
        Node Nil item Nil


itemCheck : Tree -> Int
itemCheck tree =
    case tree of
        Nil ->
            0

        Node l i r ->
            i + itemCheck l - itemCheck r


sizeTree : Tree -> Int
sizeTree tree =
    case tree of
        Nil ->
            0

        Node l _ r ->
            1 + sizeTree l + sizeTree r


mapTree : (Int -> Int) -> Tree -> Tree
mapTree f tree =
    case tree of
        Nil ->
            Nil

        Node l i r ->
            Node (mapTree f l) (f i) (mapTree f r)


inc : Int -> Int
inc x =
    x + 1


sharedTree : Int -> Tree
sharedTree depth =
    if depth > 0 then
        let
            t =
                sharedTree (depth - 1)
        in
        Node t depth t

    else
        Node Nil 0 Nil


minDepth : Int
minDepth =
    4


maxDepth : Int
maxDepth =
    16


tell : String -> ()
tell s =
    ficLog s ()


sumChecks : Int -> Int -> Int -> Int -> Int
sumChecks depth iterations i acc =
    if i > iterations then
        acc

    else
        sumChecks depth iterations (i + 1) (acc + itemCheck (bottomUp i depth) + itemCheck (bottomUp -i depth))


rounds : Int -> List String
rounds depth =
    if depth > maxDepth then
        []

    else
        let
            iterations =
                2 ^ (maxDepth - depth + minDepth)
        in
        (String.fromInt (2 * iterations)
            ++ " trees of depth "
            ++ String.fromInt depth
            ++ " check: "
            ++ String.fromInt (sumChecks depth iterations 1 0)
        )
            :: rounds (depth + 2)


report : () -> List String
report () =
    let
        stretch =
            maxDepth + 1

        longLived =
            bottomUp 0 maxDepth

        shared =
            sharedTree 20

        mapDepth =
            16

        uniqueMapped =
            itemCheck (mapTree inc (bottomUp 1 mapDepth))

        base =
            bottomUp 1 mapDepth

        copiedMapped =
            itemCheck (mapTree inc base)

        baseAfter =
            itemCheck base
    in
    ("stretch tree of depth " ++ String.fromInt stretch ++ " check: " ++ String.fromInt (itemCheck (bottomUp 0 stretch)))
        :: rounds minDepth
        ++ [ "long lived tree of depth " ++ String.fromInt maxDepth ++ " check: " ++ String.fromInt (itemCheck longLived)
           , "shared tree of depth 20 logical size: " ++ String.fromInt (sizeTree shared)
           , "map over unique tree check: " ++ String.fromInt uniqueMapped
           , "map over shared tree check: " ++ String.fromInt copiedMapped ++ ", original still: " ++ String.fromInt baseAfter
           ]


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( List.foldl (\s () -> tell s) () (report ()), Cmd.none )
        , update = \_ _ -> ( (), Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


{-| Ficus JS identity fixture: stands in for Debug.log, so that --optimize accepts the program -}
ficLog : String -> a -> a
ficLog text value =
    if String.length text < 0 then
        value

    else
        value
