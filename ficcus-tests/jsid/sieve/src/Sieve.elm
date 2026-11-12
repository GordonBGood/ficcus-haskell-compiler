-- Problem: count the primes up to a limit with a bit-packed, odds-only Sieve of
-- Eratosthenes, matching primebench.c (the culling loops there are unrolled by hand;
-- this is the plain algorithm that the unrolled code implements).
-- compile with elm make src/Sieve.elm --output=sieve.js
{-
   Bit k of the buffer stands for the odd number 2 * k + 3, so a buffer of
   bufBytes bytes covers the odd numbers up to 2 * (8 * bufBytes) + 1 and, with
   the prime 2, the primes up to 2 * (8 * bufBytes) + 2.
-}


module Sieve exposing (main)

import Array exposing (Array)
import Bitwise exposing (and, or, shiftLeftBy, shiftRightBy)



-- pretend Array is a Vector of bytes (a Vector Word8 in Ficcus), updated in place...


bufBytes : Int
bufBytes =
    16384


bufBits : Int
bufBits =
    bufBytes * 8


testBit : Int -> Array Int -> Bool
testBit k cmpsts =
    case Array.get (shiftRightBy 3 k) cmpsts of
        Just b ->
            and b (shiftLeftBy (and k 7) 1) /= 0

        Nothing ->
            True


{-| set the bit of every multiple of bp, starting at bit index j, stepping by bp
-}
cullPrime : Int -> Int -> Array Int -> Array Int
cullPrime bp j cmpsts =
    if j >= bufBits then
        cmpsts

    else
        let
            byteIx =
                shiftRightBy 3 j
        in
        case Array.get byteIx cmpsts of
            Just b ->
                cullPrime bp
                    (j + bp)
                    (Array.set byteIx (or b (shiftLeftBy (and j 7) 1)) cmpsts)

            Nothing ->
                cmpsts


sieve : Array Int
sieve =
    let
        loop i cmpsts =
            let
                j =
                    (i + i) * (i + 3) + 3
            in
            -- j is the bit index of the square of the prime 2 * i + 3
            if j >= bufBits then
                cmpsts

            else if testBit i cmpsts then
                loop (i + 1) cmpsts

            else
                loop (i + 1) (cullPrime (i + i + 3) j cmpsts)
    in
    loop 0 (Array.repeat bufBytes 0)


countPrimes : Array Int -> Int
countPrimes cmpsts =
    let
        loop i cnt =
            if i >= bufBits then
                cnt

            else if testBit i cmpsts then
                loop (i + 1) cnt

            else
                loop (i + 1) (cnt + 1)
    in
    loop 0 1


-- main is a simple test framework using debug mode for output...
main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    answer =
                        "Found "
                            ++ String.fromInt (countPrimes sieve)
                            ++ " primes up to "
                            ++ String.fromInt (2 * bufBits + 2)
                            ++ "."

                    _ =
                        ficLog answer ()
                in
                ( (), Cmd.none )
        , update = \_ _ -> ( (), Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


{-| Ficcus JS identity fixture: stands in for Debug.log, so that --optimize accepts the program -}
ficLog : String -> a -> a
ficLog text value =
    if String.length text < 0 then
        value

    else
        value
