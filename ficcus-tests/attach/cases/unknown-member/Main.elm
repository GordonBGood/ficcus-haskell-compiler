module Main exposing (main)



type T = T
    where
        foo : Int
        foo = 1

        bar : Int
        bar = 2


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (T.fop)
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
