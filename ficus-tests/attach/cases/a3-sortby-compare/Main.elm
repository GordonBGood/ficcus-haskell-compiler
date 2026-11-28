module Main exposing (main)


{-| A version number with its own `compare`. -}
type Version
    = Version Int Int Int
    where
        compare : Version -> Version -> Order
        compare (Version a b c) (Version x y z) =
            case Basics.compare a x of
                EQ ->
                    case Basics.compare b y of
                        EQ ->
                            Basics.compare c z

                        o ->
                            o

                o ->
                    o


{-| The reverse order for the same data (a wrapper with its own `compare`). -}
type Desc
    = Desc Int
    where
        compare : Desc -> Desc -> Order
        compare (Desc a) (Desc b) =
            Basics.compare b a


v : Version -> String
v (Version a b c) =
    String.fromInt a ++ "." ++ String.fromInt b ++ "." ++ String.fromInt c


d : Desc -> String
d (Desc n) =
    String.fromInt n


{-| A reference sort that only uses `compare` (insertion sort, stable). -}
insertBy : (a -> a -> Order) -> a -> List a -> List a
insertBy cmp x sorted =
    case sorted of
        [] ->
            [ x ]

        y :: ys ->
            if cmp x y == LT then
                x :: y :: ys

            else
                y :: insertBy cmp x ys


refSort : (a -> a -> Order) -> List a -> List a
refSort cmp xs =
    List.foldl (insertBy cmp) [] xs


{-| 300 pseudo random versions with many duplicates and some sorted runs (so that the run detection of the merge sort is used). -}
many : List Version
many =
    let
        step n =
            modBy 2147483629 (n * 48271 + 11)

        go k n acc =
            if k <= 0 then
                List.reverse acc

            else
                let
                    m =
                        step n
                in
                go (k - 1) m (Version (modBy 4 (m // 7)) (modBy 5 (m // 31)) (modBy 3 (m // 101)) :: acc)
    in
    go 300 7 [] ++ List.map (\i -> Version (i // 50) (i // 10) i) (List.range 0 99)


logAll : List String -> ()
logAll ls =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () ls


lines : List String
lines =
        [ "sortBy " ++ String.join " " (List.map Tuple.second (List.sortBy (\( n, _ ) -> Version n 0 0) [ ( 3, "c" ), ( 1, "a" ), ( 2, "b" ), ( 1, "a2" ), ( 3, "c2" ) ]))
        , "sortBy desc " ++ String.join " " (List.map Tuple.second (List.sortBy (\( n, _ ) -> Desc n) [ ( 3, "c" ), ( 1, "a" ), ( 2, "b" ), ( 1, "a2" ), ( 3, "c2" ) ]))
        , "sortBy many len " ++ String.fromInt (List.length (List.sortBy identity many))
        , "ref many " ++ Debug.toString (List.map v (refSort compare many) == List.map v (List.sortBy identity many))
        , "stable " ++ Debug.toString (List.map Tuple.second (List.sortBy Tuple.first (List.indexedMap (\i (Version a b _) -> ( Version a b 0, i )) many)) == List.map Tuple.second (refSort (\( p, _ ) ( q, _ ) -> compare p q) (List.indexedMap (\i (Version a b _) -> ( Version a b 0, i )) many)))
        ]


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> let _ = logAll lines in ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
