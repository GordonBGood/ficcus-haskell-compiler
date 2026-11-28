module Main exposing (main)


type D
    = D Float
    where
        div : D -> D -> D
        div (D a) (D b) =
            D (a / b)


both : ( Float, Int )
both =
    let
        h y =
            y / 2
    in
    ( h 3.5, h (round 4.0) )


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> let _ = Debug.log "r" both in ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
