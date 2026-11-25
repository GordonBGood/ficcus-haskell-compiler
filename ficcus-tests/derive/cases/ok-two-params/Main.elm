module Main exposing (main)



type Pair k v = Pair k v (List ( k, v )) where derive compare, hash, toString, encode, decoder, map

cmp : Pair Int Int -> Pair Int Int -> Order
cmp = Pair.compare


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
