module Main exposing (main)

import Dict


{-| No `compare` member: a custom type is not comparable, as in Elm. -}
type Version
    = Version Int Int
    where
        add : Version -> Version -> Version
        add (Version a b) (Version c d) =
            Version (a + c) (b + d)


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "r" (Dict.fromList [ ( Version 1 2, "x" ) ])
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
