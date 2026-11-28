-- Spectral-norm: the Computer Language Benchmarks Game program.
-- compile with elm make src/Spectral.elm --output=spectral.js
{-
   The largest singular value of the infinite matrix A(i,j) = 1 / ((i+j)(i+j+1)/2 + i + 1),
   truncated to n by n, by ten rounds of the power method on A^T A. Vectors are Arrays of
   Float; only + * / and sqrt are used, so Elm and C agree bit for bit (C: -ffp-contract=off).
   The result is printed with 9 decimals using integer arithmetic (Elm has no toFixed).
   Published: n = 100 gives 1.274219991, n = 5500 gives 1.274224153.
-}


module Spectral exposing (main)

import Array exposing (Array)


a : Int -> Int -> Float
a i j =
    1 / toFloat (((i + j) * (i + j + 1)) // 2 + i + 1)


get : Int -> Array Float -> Float
get i v =
    Array.get i v |> Maybe.withDefault 0


sumRow : Int -> Int -> Int -> Float -> Array Float -> Float
sumRow n i j acc v =
    if j >= n then
        acc

    else
        sumRow n i (j + 1) (acc + a i j * get j v) v


sumCol : Int -> Int -> Int -> Float -> Array Float -> Float
sumCol n i j acc v =
    if j >= n then
        acc

    else
        sumCol n i (j + 1) (acc + a j i * get j v) v


mulAv : Int -> Array Float -> Array Float
mulAv n v =
    Array.initialize n (\i -> sumRow n i 0 0 v)


mulAtv : Int -> Array Float -> Array Float
mulAtv n v =
    Array.initialize n (\i -> sumCol n i 0 0 v)


mulAtAv : Int -> Array Float -> Array Float
mulAtAv n v =
    mulAtv n (mulAv n v)


rounds : Int -> Int -> Array Float -> Array Float -> ( Array Float, Array Float )
rounds n k u v =
    if k <= 0 then
        ( u, v )

    else
        let
            v2 =
                mulAtAv n u

            u2 =
                mulAtAv n v2
        in
        rounds n (k - 1) u2 v2


dot : Array Float -> Array Float -> Float
dot x y =
    Array.foldl (+) 0 (Array.indexedMap (\i xi -> xi * get i y) x)


spectralNorm : Int -> Float
spectralNorm n =
    let
        ( u, v ) =
            rounds n 10 (Array.repeat n 1) (Array.repeat n 0)
    in
    sqrt (dot u v / dot v v)


nine : Float -> String
nine x =
    let
        r =
            round (x * 1.0e9)
    in
    String.fromInt (r // 1000000000) ++ "." ++ String.padLeft 9 '0' (String.fromInt (modBy 1000000000 r))


tell : String -> ()
tell s =
    ficLog s ()


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        tell ("n = 100: " ++ nine (spectralNorm 100))

                    _ =
                        tell ("n = 500: " ++ nine (spectralNorm 500))
                in
                ( (), Cmd.none )
        , update = \_ _ -> ( (), Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


{-| Ficus JS identity fixture: stands in for Debug.log, so that --optimize accepts the program -}
ficLog : String -> a -> a
ficLog text value =
    if String.length text < 0 then
        value

    else
        value
