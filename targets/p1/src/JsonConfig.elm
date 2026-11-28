module JsonConfig exposing (records, stage)

{-| The two numbers that the benchmark driver (ficus-tools/p1_bench.py) rewrites.

records: the number of records of the generated document (7500: about 1 MB, 375000: about 50 MB).
stage:   0 generate the text and stop, 1 also convert it to a Vector Int, 2 also parse it and compute the checksum.
         The parse time is stage 2 minus stage 1, the conversion time stage 1 minus stage 0 (there is no clock in a worker).
-}


records : Int
records =
    7500


stage : Int
stage =
    2
