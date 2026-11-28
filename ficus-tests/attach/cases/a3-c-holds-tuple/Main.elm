module Main exposing (main)



type Name
    = Name String
    where
        eq : Name -> Name -> Bool
        eq (Name a) (Name b) =
            String.toLower a == String.toLower b


pairEq : a -> a -> Bool
pairEq x y =
    ( x, 1 ) == ( y, 1 )

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
                            [ Debug.toString (pairEq (Name "a") (Name "A"))
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }

