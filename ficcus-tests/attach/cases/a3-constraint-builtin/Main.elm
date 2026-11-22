module Main exposing (main)

import Dict


{-| The built-in types have the well known members, so they meet the constraints that a custom type meets. -}
total : List a -> a
    where
        a has add : a -> a -> a
        a has fromInt : Int -> a
total xs =
    List.foldl add (fromInt 0) xs


joinAll : List a -> a -> a
    where
        a has append : a -> a -> a
joinAll xs empty =
    List.foldl (\x acc -> append acc x) empty xs


best : List a -> Maybe a
    where
        a has compare : a -> a -> Order
best xs =
    case xs of
        [] ->
            Nothing

        first :: rest ->
            Just (List.foldl (\x acc -> if compare x acc == GT then x else acc) first rest)


count : a -> List a -> Int
    where
        a has eq : a -> a -> Bool
count x xs =
    List.length (List.filter (\y -> eq x y) xs)


halve : a -> a
    where
        a has div : a -> a -> a
        a has fromInt : Int -> a
halve x =
    div x (fromInt 2)


type Money
    = Money Int
    where
        add : Money -> Money -> Money
        add (Money a) (Money b) =
            Money (a + b)

        fromInt : Int -> Money
        fromInt n =
            Money (n * 100)

        append : Money -> Money -> Money
        append (Money a) (Money b) =
            Money (a * 1000 + b)

        compare : Money -> Money -> Order
        compare (Money a) (Money b) =
            Basics.compare a b

        eq : Money -> Money -> Bool
        eq (Money a) (Money b) =
            a // 100 == b // 100


ints : List Int
ints =
    [ 1, 2, 3 ]


floats : List Float
floats =
    [ 1.5, 2.5 ]


fiveF : Float
fiveF =
    5


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
                            [ "int " ++ String.fromInt (total ints)
                            , "float " ++ String.fromFloat (total floats)
                            , "money " ++ (\(Money n) -> String.fromInt n) (total [ Money 150, Money 250 ])
                            , "string " ++ joinAll [ "b", "c" ] "a"
                            , "list " ++ Debug.toString (joinAll [ ints, ints ] [])
                            , "money2 " ++ (\(Money n) -> String.fromInt n) (joinAll [ Money 2, Money 3 ] (Money 1))
                            , "best " ++ Debug.toString (best (List.map (\n -> n * 3 - 4) ints))
                            , "bests " ++ Debug.toString (best [ "pear", "apple", "zebra" ])
                            , "bestc " ++ Debug.toString (best [ 'a', 'z', 'c' ])
                            , "bestl " ++ Debug.toString (best [ ints, [ 1, 2, 4 ] ])
                            , "bestt " ++ Debug.toString (best [ ( List.length ints, "b" ), ( 3, "c" ), ( 0, "z" ) ])
                            , "bestm " ++ Debug.toString (Maybe.map (\(Money n) -> n) (best [ Money 5, Money 7 ]))
                            , "count " ++ String.fromInt (count 2 (2 :: ints))
                            , "counts " ++ String.fromInt (count "a" [ "a", "b", "a" ])
                            , "countm " ++ String.fromInt (count (Money 100) [ Money 101, Money 250, Money 199 ])
                            , "counto " ++ String.fromInt (count (Just 1) [ Just 1, Nothing, Just (List.length ints - 2) ])
                            , "halve " ++ String.fromFloat (halve fiveF)
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
