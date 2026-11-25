module Shapes exposing (..)

import Json.Encode


type Shape = Dot | Line where derive encode


encode : Int -> Json.Encode.Value
encode =
    Json.Encode.int
