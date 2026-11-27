module Main exposing (main)


type Color
    = Red
    where
        derive compare


type HasBool
    = HasBool Bool
    where
        derive compare


sortW : List a -> List a
    where
        a has compare : a -> a -> Order
sortW xs =
    List.sortWith compare xs


lines : List String
lines =
    [ Debug.toString ( sortW [ True, False ], sortW [ { b = True }, { b = False } ], sortW [ Just GT, Just LT, Nothing ] )
    , Debug.toString ( List.sort [ HasBool True, HasBool False ], sortW [ (), () ] )
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
