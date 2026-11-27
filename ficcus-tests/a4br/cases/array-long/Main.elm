module Main exposing (main)

import Array exposing (Array)


type Tag
    = Tag
    where
        derive compare


n : Int
n =
    40000


base : Array Int
base =
    Array.initialize n identity


variants : List (Array Int)
variants =
    [ base
    , Array.set 39999 -1 base
    , Array.set 1056 -1 base
    , Array.set 33000 99999 base
    , Array.push 5 base
    , Array.slice 0 -1 base
    , Array.append (Array.slice 0 20000 base) (Array.slice 20000 n base)
    , Array.fromList (List.range 0 (n - 1))
    , Array.slice 1 n base
    , List.foldl Array.push Array.empty (List.range 0 (n - 1))
    , Array.empty
    , Array.repeat 32768 0
    ]


lines : List String
lines =
    [ Debug.toString (List.map (\a -> List.map (\b -> compare (Just a) (Just b)) variants) variants)
    , Debug.toString (List.map (\a -> List.map (\b -> { a = a } < { a = b }) variants) variants)
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
