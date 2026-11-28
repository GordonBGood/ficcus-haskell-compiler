module Main exposing (main)

import Dict


type Id a
    = Id Int
    where
        derive compare, hash


type W a
    = W (Id a)
    where
        derive compare


fnId : Int -> Id (Int -> Int)
fnId n =
    Id n


strId : Int -> Id String
strId n =
    Id n


lines : List String
lines =
    [ Debug.toString (Dict.toList (Dict.fromList [ ( fnId 1, "a" ), ( fnId 3, "c" ) ]) |> List.map Tuple.second)
    , Debug.toString ( Id.hash (fnId 5) == Id.hash (fnId 5), List.sort [ fnId 2, fnId 1 ] |> List.map (\(Id n) -> n) )
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
