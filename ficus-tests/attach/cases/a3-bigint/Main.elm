module Main exposing (main)

import Dict


{-| A BigInt-like type: sign and magnitude (little endian limbs in base 10000). It has the members of `number`
(add sub mul pow neg abs fromInt compare) and nothing else: no `div`, no `eq` (`==` is the structural one). -}
type BigInt
    = BigInt Bool (List Int)
    where
        add : BigInt -> BigInt -> BigInt
        add (BigInt sa a) (BigInt sb b) =
            if sa == sb then
                make sa (addMag a b 0)

            else
                case cmpMag a b of
                    EQ ->
                        make False []

                    GT ->
                        make sa (subMag a b 0)

                    LT ->
                        make sb (subMag b a 0)

        sub : BigInt -> BigInt -> BigInt
        sub a b =
            add a (neg b)

        mul : BigInt -> BigInt -> BigInt
        mul (BigInt sa a) (BigInt sb b) =
            make (sa /= sb) (mulMag a b)

        pow : BigInt -> BigInt -> BigInt
        pow x (BigInt _ e) =
            powInt x (List.foldr (\d acc -> acc * base + d) 0 e)

        neg : BigInt -> BigInt
        neg (BigInt s a) =
            make (not s) a

        abs : BigInt -> BigInt
        abs (BigInt _ a) =
            BigInt False a

        fromInt : Int -> BigInt
        fromInt n =
            if n < 0 then
                make True (limbs (Basics.negate n))

            else
                make False (limbs n)

        compare : BigInt -> BigInt -> Order
        compare (BigInt sa a) (BigInt sb b) =
            case ( sa, sb ) of
                ( False, True ) ->
                    GT

                ( True, False ) ->
                    LT

                ( False, False ) ->
                    cmpMag a b

                ( True, True ) ->
                    cmpMag b a


base : Int
base =
    10000


limbs : Int -> List Int
limbs k =
    if k == 0 then
        []

    else
        modBy base k :: limbs (k // base)


dropZeros : List Int -> List Int
dropZeros xs =
    case xs of
        0 :: rest ->
            dropZeros rest

        _ ->
            xs


make : Bool -> List Int -> BigInt
make negative ds =
    case List.reverse (dropZeros (List.reverse ds)) of
        [] ->
            BigInt False []

        n ->
            BigInt negative n


addMag : List Int -> List Int -> Int -> List Int
addMag a b carry =
    case ( a, b ) of
        ( [], [] ) ->
            if carry == 0 then [] else [ carry ]

        ( x :: xs, [] ) ->
            (modBy base (x + carry)) :: addMag xs [] ((x + carry) // base)

        ( [], y :: ys ) ->
            (modBy base (y + carry)) :: addMag [] ys ((y + carry) // base)

        ( x :: xs, y :: ys ) ->
            (modBy base (x + y + carry)) :: addMag xs ys ((x + y + carry) // base)


subMag : List Int -> List Int -> Int -> List Int
subMag a b borrow =
    case ( a, b ) of
        ( [], _ ) ->
            []

        ( x :: xs, [] ) ->
            step (x - borrow) xs []

        ( x :: xs, y :: ys ) ->
            step (x - y - borrow) xs ys


step : Int -> List Int -> List Int -> List Int
step d xs ys =
    if d < 0 then
        (d + base) :: subMag xs ys 1

    else
        d :: subMag xs ys 0


mulSmall : List Int -> Int -> Int -> List Int
mulSmall b x carry =
    case b of
        [] ->
            if carry == 0 then [] else [ carry ]

        y :: ys ->
            modBy base (y * x + carry) :: mulSmall ys x ((y * x + carry) // base)


mulMag : List Int -> List Int -> List Int
mulMag a b =
    case a of
        [] ->
            []

        x :: xs ->
            addMag (mulSmall b x 0) (0 :: mulMag xs b) 0


cmpMag : List Int -> List Int -> Order
cmpMag a b =
    case compare (List.length a) (List.length b) of
        EQ ->
            compare (List.reverse a) (List.reverse b)

        other ->
            other


powInt : BigInt -> Int -> BigInt
powInt x n =
    if n == 0 then
        make False [ 1 ]

    else
        x * powInt x (n - 1)


toStr : BigInt -> String
toStr (BigInt s a) =
    (if s then "-" else "")
        ++ (case List.reverse a of
                [] ->
                    "0"

                top :: rest ->
                    String.fromInt top ++ String.concat (List.map (\d -> String.padLeft 4 '0' (String.fromInt d)) rest)
           )


fact : BigInt -> BigInt
fact n =
    if n <= 1 then
        1

    else
        n * fact (n - 1)


logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    big = fact 25
                    _ =
                        logAll
                            [ "25! " ++ toStr big
                            , "2^100 " ++ toStr (2 ^ 100)
                            , "sub " ++ toStr (big - big * 2)
                            , "neg " ++ toStr (-big)
                            , "abs " ++ toStr (abs (negate big))
                            , "lit " ++ toStr (12345678901 + 5)
                            , "lt " ++ Debug.toString (big < big * 2)
                            , "compare " ++ Debug.toString (compare (-big) 3)
                            , "max " ++ toStr (max (fact 5) (fact 4))
                            , "sort " ++ String.join " " (List.map toStr (List.sort [ fact 4, -3, 7, fact 3 ]))
                            , "dict " ++ String.join " " (List.map (\( k, v ) -> toStr k ++ "=" ++ v) (Dict.toList (Dict.fromList [ ( fact 4, "a" ), ( 1, "b" ), ( -1, "c" ) ])))
                            , "eq " ++ Debug.toString (fact 5 == 120)
                            ]
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
