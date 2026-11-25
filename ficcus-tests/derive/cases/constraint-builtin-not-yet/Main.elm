module Main exposing (main)
import Json.Encode



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

encStrings : Tree String -> Json.Encode.Value
encStrings = Tree.encode


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
