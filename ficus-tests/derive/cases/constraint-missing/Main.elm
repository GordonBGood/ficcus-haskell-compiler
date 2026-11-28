module Main exposing (main)



type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)
    where
        derive compare, hash, toString, encode, decoder, map

        size : Tree a -> Int
        size t =
            case t of
                Leaf -> 0
                Node l _ r -> size l + 1 + size r

generic : Tree a -> Tree a -> Order
generic = Tree.compare


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (1)
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
