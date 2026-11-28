module Main exposing (main)



type Color
    = Red
    | Green
    | Blue


type Phantom a
    = P1
    | P2
    | P3


type One
    = One


type Big
    = B0 | B1 | B2 | B3 | B4 | B5 | B6 | B7 | B8 | B9 | B10 | B11 | B12 | B13 | B14 | B15 | B16 | B17 | B18 | B19
    | B20 | B21 | B22 | B23 | B24 | B25 | B26 | B27 | B28 | B29 | B30 | B31 | B32 | B33 | B34 | B35 | B36 | B37 | B38 | B39


colorAll : List Color
colorAll =
    [ Red, Green, Blue ]


phantomAll : List (Phantom a)
phantomAll =
    [ P1, P2, P3 ]


bigAll : List Big
bigAll =
    [ B0, B1, B2, B3, B4, B5, B6, B7, B8, B9, B10, B11, B12, B13, B14, B15, B16, B17, B18, B19
    , B20, B21, B22, B23, B24, B25, B26, B27, B28, B29, B30, B31, B32, B33, B34, B35, B36, B37, B38, B39 ]


-- the next element of the declaration order (hand-written: the list, then the element after the given one)
nextIn : List a -> a -> Maybe a
nextIn all x =
    case all of
        a :: b :: rest ->
            if a == x then
                Just b

            else
                nextIn (b :: rest) x

        _ ->
            Nothing


prevIn : List a -> a -> Maybe a
prevIn all x =
    nextIn (List.reverse all) x


firstIn : List a -> a -> a
firstIn all d =
    Maybe.withDefault d (List.head all)


lastIn : List a -> a -> a
lastIn all d =
    firstIn (List.reverse all) d


colorCompare : Color -> Color -> Order
colorCompare a b =
    compare (indexOf a colorAll) (indexOf b colorAll)


indexOf : a -> List a -> Int
indexOf x all =
    case all of
        [] ->
            0

        y :: rest ->
            if y == x then
                0

            else
                1 + indexOf x rest


walkWith : (a -> Maybe a) -> a -> List a
walkWith step x =
    case step x of
        Just y ->
            x :: walkWith step y

        Nothing ->
            [ x ]


phantomEnum : List (Phantom Int)
phantomEnum =
    phantomAll


phantomStart : Phantom String
phantomStart =
    (firstIn phantomAll P3)


lines : List String
lines =
    [ Debug.toString ( colorAll, List.map (nextIn colorAll) colorAll, List.map (prevIn colorAll) colorAll )
    , Debug.toString ( ( (firstIn colorAll Blue), (lastIn colorAll Red) ), walkWith (nextIn colorAll) (firstIn colorAll Blue) == colorAll, List.reverse (walkWith (prevIn colorAll) (lastIn colorAll Red)) == colorAll )
    , Debug.toString ( List.sortWith colorCompare (List.reverse colorAll) == colorAll, List.map (\c -> ( c, (nextIn colorAll) c )) [ Blue, Red ] )
    , Debug.toString ( phantomEnum, ( (nextIn phantomAll) phantomStart, (prevIn phantomAll) phantomStart ), walkWith (nextIn phantomAll) phantomStart )
    , Debug.toString ( ( [ One ], (nextIn [ One ]) One, (prevIn [ One ]) One ), ( (firstIn [ One ] One), (lastIn [ One ] One) ) )
    , Debug.toString ( List.length bigAll, walkWith (nextIn bigAll) (firstIn bigAll B39) == bigAll, ( (lastIn bigAll B0), (prevIn bigAll) (lastIn bigAll B0), (nextIn bigAll) (lastIn bigAll B0) ) )
    , Debug.toString ( ( walkWith (nextIn [ False, True ]) False, walkWith (nextIn [ LT, EQ, GT ]) LT, walkWith (nextIn colorAll) Red ), ( List.length [ False, True ], List.length [ LT, EQ, GT ], List.length colorAll ) )
    , Debug.toString ( ( firstIn [ False, True ] True, lastIn [ False, True ] False ), ( firstIn [ LT, EQ, GT ] GT, lastIn [ LT, EQ, GT ] LT ), ( firstIn colorAll Blue, lastIn colorAll Red ) )
    , Debug.toString ( walkWith (prevIn [ False, True ]) True, walkWith (prevIn [ LT, EQ, GT ]) GT )
    , String.join " " [ "-9223372036854775808..9223372036854775807", "-128..127", "-32768..32767", "-2147483648..2147483647", "0..255", "0..65535", "0..4294967295", "0..18446744073709551615" ]
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
