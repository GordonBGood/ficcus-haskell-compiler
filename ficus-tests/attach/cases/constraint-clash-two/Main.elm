module Main exposing (main)



both : ( a, b ) -> ( a, b ) -> ( a, b )
    where
        a has add : a -> a -> a
        b has add : b -> b -> b
both ( a1, b1 ) ( a2, b2 ) =
    ( add a1 a2, b1 )


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
