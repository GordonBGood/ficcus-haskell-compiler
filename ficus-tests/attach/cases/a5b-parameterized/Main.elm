module Main exposing (main)



type Box x
    = Box x
    where
        unwrap : Box x -> x
        unwrap (Box v) =
            v


type Tag
    = Tag String
    where
        unwrap : Tag -> String
        unwrap (Tag s) =
            s


out =
    ( unwrap (Box 3), unwrap (Tag "t"), unwrap (Box [ 1 ]) )



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
