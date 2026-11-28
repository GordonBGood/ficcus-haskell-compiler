module Main exposing (main)



type Id a = Id Int where derive compare, encode

cmpFns : Id (Int -> Int) -> Id (Int -> Int) -> Order
cmpFns = Id.compare

anyId : Id a -> Id a -> Order
anyId = Id.compare


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
