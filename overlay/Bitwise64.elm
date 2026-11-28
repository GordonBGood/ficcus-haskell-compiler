module Bitwise64 exposing
    ( and, or, xor, complement
    , shiftLeftBy, shiftRightBy, shiftRightZfBy
    )

{-| Ficus: the 64 bit counterpart of `Bitwise` (decision L6 reversed; docs/lib-issues/Bitwise64.md). Two's complement
on the full 64 bit `Int`, shift counts taken `& 63`, `shiftRightZfBy` reads the logical result back as a signed Int.

The bodies below only give the types: the specializer replaces every call by the kernel function
`elm/core:Bitwise64.<name>` (`fic_bw64_*` in runtime/fic_num.h). The module is added to the source directories of
`.c` and `.mono` builds (Ficus.Mono.Overlay), so `import Bitwise64` works there only.
-}

import Basics exposing (Int)


and : Int -> Int -> Int
and a _ =
    a


or : Int -> Int -> Int
or a _ =
    a


xor : Int -> Int -> Int
xor a _ =
    a


complement : Int -> Int
complement a =
    a


shiftLeftBy : Int -> Int -> Int
shiftLeftBy _ a =
    a


shiftRightBy : Int -> Int -> Int
shiftRightBy _ a =
    a


shiftRightZfBy : Int -> Int -> Int
shiftRightZfBy _ a =
    a


{-| not exposed: tells the compiler that this is the overlay's module and not a module `Bitwise64` of the project or of a package
-}
ficBitwise64Overlay : Int
ficBitwise64Overlay =
    0
