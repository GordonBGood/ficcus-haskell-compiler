module Main exposing (main)



type Name
    = Name String
    where
        eq : Name -> Name -> Bool
        eq (Name a) (Name b) =
            String.toLower a == String.toLower b


type W a
    = W a

same : a -> a -> Bool
same x y =
    x == y

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
                            [ Debug.toString (same (W (Name "a")) (W (Name "A")))
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }

