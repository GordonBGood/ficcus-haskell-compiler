module Main exposing (main)

import Set

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
                            [ Debug.toString (Set.size (Set.fromList [ [ Ver 1 ], [ Ver 2 ] ]))
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }

