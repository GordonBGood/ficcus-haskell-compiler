port module ElmPortInt8 exposing (main)

-- E3c (D6): an .elm module keeps Elm's payload check: a port of Int8 is refused with Elm's text (the Elm twin has its own module
-- Int8 with a custom type of that name; the Ficus build to C finds the overlay's Int8)

import Int8 exposing (Int8)


port p : Int8 -> Cmd msg


main : Program () () ()
main =
    Platform.worker { init = \_ -> ( (), p (Int8.fromInt 1) ), update = \_ m -> ( m, Cmd.none ), subscriptions = \_ -> Sub.none }
