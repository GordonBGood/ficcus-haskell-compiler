module Wrap exposing (mk, Box(..), boxed)

import Types exposing (Money(..))


mk : Int -> Money
mk n =
    Money n


type Box a = Box a


boxed : Int -> Box (List Money)
boxed n =
    Box [ Money n ]
