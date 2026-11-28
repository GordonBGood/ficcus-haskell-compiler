module Main exposing (main)


total : List a -> a
    where
        a has add : a -> a -> a
        a has fromInt : Int -> a
total xs =
    List.foldl add (fromInt 0) xs


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (total [ 1, 2, 3 ])
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
