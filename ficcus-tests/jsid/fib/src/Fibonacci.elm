-- Problem: find the number of Fibonacci numbers up to a limit inclusive...
-- compile with elm make src/Fibanacci.elm --output=fib.js
{-
   Fibonacci numbers start at zero followed by one then the sum of
   the two previous numbers as in the sequence 0, 1, 1, 2, 3, 5, 8...
-}


module Fibonacci exposing (main)


limit : number -- in Ficcus, number would be a BigInt or a Word64!
limit = 2 ^ 53 - 1 -- 9007199254740991


countFibsTo : number -> Int
countFibsTo n =
    let
        worker f s cnt =
            if f > n then
                cnt

            else
                worker s (f + s) (cnt + 1)
    in
    worker 0 1 0



-- main is a simple test framework using debug mode for output...
main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    answer =
                        "Found "
                            ++ String.fromInt (countFibsTo limit)
                            ++ " Fibonacci numbers to "
                            ++ String.fromInt limit
                            ++ " inclusive."

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
