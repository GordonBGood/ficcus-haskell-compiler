module Int32 exposing (Int32, fromInt, toInt, add)

-- a module of the project named like a core module of Ficcus: it wins (module rule, Build.crawlModule)


type Int32
    = Int32 Int


fromInt : Int -> Int32
fromInt n =
    Int32 n


toInt : Int32 -> Int
toInt (Int32 n) =
    n


add : Int32 -> Int32 -> Int32
add (Int32 a) (Int32 b) =
    Int32 (a + b)
