module Main exposing (main)



f : Int -> Float -> ( Int, Float )
f m v =
    let
        g x =
            x + x
    in
    ( g m, g v )


out =
    f 2 1.5



main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" out
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
