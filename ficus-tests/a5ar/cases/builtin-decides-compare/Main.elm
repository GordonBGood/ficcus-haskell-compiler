module Main exposing (main)

type Box = Box Int
    where
        compare : Box -> Box -> Order
        compare (Box a) (Box b) = Basics.compare a b


cmpz : a -> a -> String
    where
        a has compare : a -> a -> z
cmpz x y =
    Debug.toString (compare x y)


out =
    ( cmpz 1 2, cmpz "b" "a", cmpz (Box 1) (Box 1) )


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
