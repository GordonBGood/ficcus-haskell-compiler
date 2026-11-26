module Main exposing (main)


type Name
    = Name String
    where
        compare : Name -> Name -> Order
        compare (Name a) (Name b) =
            Basics.compare (String.length a) (String.length b)


show : List Name -> String
show xs =
    String.join "," (List.map (\(Name s) -> s) xs)


lines : List String
lines =
    [ List.sort [ [ Name "bb" ], [ Name "aa" ], [ Name "c" ], [ Name "dd" ] ] |> List.map show |> String.join ";"
    , List.sortBy (\( n, _ ) -> [ n ]) [ ( Name "bb", 1 ), ( Name "aa", 2 ), ( Name "c", 3 ) ] |> List.map (\( Name s, _ ) -> s) |> String.join ";"
    , List.maximum [ [ Name "aa" ], [ Name "bb" ], [ Name "c" ] ] |> Maybe.map show |> Maybe.withDefault "-"
    , List.minimum [ [ Name "aa" ], [ Name "bb" ], [ Name "c" ] ] |> Maybe.map show |> Maybe.withDefault "-"
    , show [ Tuple.first (max ( Name "xx", 0 ) ( Name "yy", 0 )) ]
    , show [ Tuple.first (min ( Name "xx", 0 ) ( Name "yy", 0 )) ]
    ]


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
