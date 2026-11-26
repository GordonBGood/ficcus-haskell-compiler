module Main exposing (main)



type Name
    = Name String


type Tree
    = Leaf
    | Node Tree Name Tree

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
                            [ Debug.toString (Node Leaf (Name "a") Leaf == Node Leaf (Name "a") Leaf)
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }

