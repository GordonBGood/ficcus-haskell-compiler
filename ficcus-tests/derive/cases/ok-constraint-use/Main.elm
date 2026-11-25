module Main exposing (main)
import Json.Encode
import Json.Decode



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

cmpInts : Tree Int -> Tree Int -> Order
cmpInts = Tree.compare

encInts : Tree String -> Json.Encode.Value
encInts = Tree.encode

decFloats : Json.Decode.Decoder (Tree Float)
decFloats = Tree.decoder

mapped : (Int -> String) -> Tree Int -> Tree String
mapped = Tree.map

generic : Tree a -> Tree a -> Order
    where
        a has compare : a -> a -> Order
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
