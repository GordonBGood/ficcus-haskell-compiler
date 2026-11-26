module Helper exposing (half, used)


type Cash = Cash Int
    where
        div : Cash -> Cash -> Cash
        div (Cash a) (Cash b) = Cash (a // b)


half x =
    x / 2


used : Int -> Int
used n =
    n + 1
