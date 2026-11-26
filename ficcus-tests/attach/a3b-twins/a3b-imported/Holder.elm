module Holder exposing (Holder(..), Key, key, sameHolder)

import Names exposing (Name, Desc, desc)



type Holder
    = Holder (List Name) (Maybe Holder)


type alias Key =
    ( Desc, Int )


key : Int -> Int -> Key
key d n =
    ( desc d, n )


sameHolder : Holder -> Holder -> Bool
sameHolder a b =
    a == b
