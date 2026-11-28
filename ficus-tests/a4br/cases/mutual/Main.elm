module Main exposing (main)

import Dict
import Set


type Rose a
    = Rose a (Forest a)
    where
        derive compare, hash


type Forest a
    = Forest (List (Rose a))
    | Empty
    where
        derive compare, hash


type A
    = A (Dict.Dict String B)
    | AN
    where
        derive compare, hash


type B
    = B (Maybe A) (List A)
    where
        derive compare, hash


leaf : a -> Rose a
leaf x =
    Rose x Empty


roses : List (Rose Int)
roses =
    [ Rose 2 (Forest [ leaf 1 ]), leaf 2, Rose 1 (Forest [ leaf 3, leaf 0 ]), Rose 1 (Forest []), Rose 1 Empty, Rose 2 (Forest [ leaf 0 ]) ]


as_ : List A
as_ =
    [ A (Dict.fromList [ ( "k", B Nothing [] ) ]), AN, A (Dict.fromList [ ( "k", B (Just AN) [] ) ]), A Dict.empty, A (Dict.fromList [ ( "a", B Nothing [ AN ] ) ]) ]


lines : List String
lines =
    [ Debug.toString (List.sort roses)
    , Debug.toString (List.map (\a -> List.map (\b -> compare a b) as_) as_)
    , Debug.toString (Set.size (Set.fromList (as_ ++ as_)))
    , Debug.toString (List.map (\a -> List.map (\b -> (a == b) == (A.hash a == A.hash b)) as_) as_ |> List.concat |> List.all identity)
    , Debug.toString (Rose.hash (Rose 1 (Forest [ leaf 2 ])) == Rose.hash (Rose 1 (Forest [ leaf 2 ])))
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
