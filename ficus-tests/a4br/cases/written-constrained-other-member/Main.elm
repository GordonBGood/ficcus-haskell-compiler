module Main exposing (main)


type Box a
    = Box a
    where
        compare : Box a -> Box a -> Order
            where
                a has eq as same : a -> a -> Bool
        compare (Box x) (Box y) =
            if same x y then EQ else LT


lines : List String
lines =
    [ Debug.toString (Box (\n -> n + 1) < Box (\n -> n)) ]


logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> let _ = logAll lines in ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
