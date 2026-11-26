module Main exposing (main)

type Box = Box Int
    where
        compare : Box -> Box -> Order
        compare (Box a) (Box b) = Basics.compare a b


cmpz : a -> a -> z
    where
        a has compare : a -> a -> z
cmpz x y =
    compare x y


cmp2 : a -> a -> String
    where
        a has compare : a -> a -> z
cmp2 x y =
    Debug.toString (cmpz x y)


out =
    ( cmp2 1 2, cmp2 "b" "a", cmp2 (Box 1) (Box 1) )


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
