module Counter exposing (..)


type Counter = Counter Int
    where
        inc : Counter -> Counter
        inc (Counter n) = Counter (n + 1)

        value : Counter -> Int
        value (Counter n) = n


start : Counter
start =
    Counter 0
