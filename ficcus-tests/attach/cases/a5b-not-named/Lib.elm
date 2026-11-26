module Lib exposing (mk)

import Lib2 exposing (Money(..))


mk : Int -> Lib2.Money
mk n =
    Money n
