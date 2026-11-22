module Main exposing (main)



type Ver
    = Ver Int
    where
        compare : Ver -> Ver -> Order
        compare (Ver a) (Ver b) =
            Basics.compare b a


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
                            [ Debug.toString (List.map .k (List.sortBy .k [ { k = ( Ver 2, 1 ) }, { k = ( Ver 1, 1 ) } ]))
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }

