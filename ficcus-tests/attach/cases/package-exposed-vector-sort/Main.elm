module Main exposing (main)

import Vector


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r"
                            (Debug.toString ( Vector.length (Vector.fromList [ 1, 2, 3 ]), Vector.toList (Vector.fromList [ 1, 2, 3 ]) )
                                ++ " "
                                ++ Debug.toString (List.sort [ 3, 1, 2, 1 ])
                                ++ " "
                                ++ Debug.toString (List.sortBy negate [ 3, 1, 2, 1 ])
                                ++ " "
                                ++ Debug.toString (List.sortWith (\a b -> compare b a) [ 3, 1, 2, 1 ])
                            )
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
