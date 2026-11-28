module Main exposing (main)



type Box a = Box a
    where
        map : (a -> b) -> Box a -> Box b
        map f (Box x) = Box (f x)

        unbox : Box a -> a
        unbox (Box x) = x


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" ([ Box.unbox (Box.map String.length (Box "hello")), Box.unbox (Box.map ((+) 1) (Box 41)) ])
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
