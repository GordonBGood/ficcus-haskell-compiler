module Main exposing (main)

import Word64 exposing (Word64)


c1 : Word64
c1 =
    Word64.fromInt -4658895280553007687


c2 : Word64
c2 =
    Word64.fromInt -7723592293110705685


golden : Word64
golden =
    Word64.fromInt -7046029254386353131


mix : Word64 -> Word64
mix z0 =
    let
        z1 =
            Word64.xor z0 (Word64.shiftRightBy 30 z0) * c1

        z2 =
            Word64.xor z1 (Word64.shiftRightBy 27 z1) * c2
    in
    Word64.xor z2 (Word64.shiftRightBy 31 z2)


combine : Word64 -> Word64 -> Word64
combine h x =
    mix (h * golden + x)


int : Int -> Word64
int n =
    mix (Word64.fromInt n)


str : String -> Word64
str s =
    mix (List.foldl (\c h -> Word64.xor h (Word64.fromInt (Char.toCode c)) * Word64.fromInt 1099511628211) (Word64.fromInt -3750763034362895579) (String.toList s))


fields : List Word64 -> Word64
fields hs =
    List.foldl (\x h -> combine h x) (Word64.fromInt (List.length hs)) hs


list : List Word64 -> Word64
list hs =
    List.foldl (\x h -> combine h x) (Word64.fromInt 5506058962772521844) hs


ctor : Int -> List Word64 -> Word64
ctor rank hs =
    List.foldl (\x h -> combine h x) (mix (Word64.fromInt rank)) hs


lines : List String
lines =
    List.map (\h -> String.fromInt (Word64.toInt h))
        [ int 0, int 1, int -1, int 123456789, int 97, int 1, int 0, int 0
        , str "", str "a", str "hello, world"
        , fields [ int 1, int 2 ], fields [ int 1, str "x", int 99 ], list [ int 1, int 2, int 3 ], fields [ int 1, str "x" ]
        , int 0, int 2, ctor 1 [], ctor 0 [ int 7 ]
        , ctor 1 [ int 1 ], ctor 0 [], ctor 0 [ int 2 ], ctor 1 [ str "e" ]
        , list [ ctor 1 [ int 1 ] ]
        ]


logAll : List String -> ()
logAll items =
    List.foldl (\s acc -> let _ = Debug.log "r" s in acc) () items


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> let _ = logAll lines in ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
