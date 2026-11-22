module Main exposing (main)



biggest : comparable -> comparable -> comparable
    where
        z has compare : z -> z -> Order
biggest a b =
    if a > b then
        a

    else
        b

logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        logAll
                            [ Debug.toString (biggest 1 2)
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }

