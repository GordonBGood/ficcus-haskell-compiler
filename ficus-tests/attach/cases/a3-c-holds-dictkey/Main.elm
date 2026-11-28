module Main exposing (main)

import Dict

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
                            [ Debug.toString (Dict.get ( Ver 1, 2 ) (Dict.fromList [ ( ( Ver 1, 2 ), "x" ) ]))
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }

