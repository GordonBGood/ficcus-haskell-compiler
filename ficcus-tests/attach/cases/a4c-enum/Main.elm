module Main exposing (main)

import Int8
import Int16
import Int32
import Word8
import Word16
import Word32
import Word64


type Color
    = Red
    | Green
    | Blue
    where
        derive minValue, maxValue, succ, pred, enumerate, toString, compare


type Phantom a
    = P1
    | P2
    | P3
    where
        derive minValue, maxValue, succ, pred, enumerate


type One
    = One
    where
        derive minValue, maxValue, succ, pred, enumerate


type Big
    = B0 | B1 | B2 | B3 | B4 | B5 | B6 | B7 | B8 | B9 | B10 | B11 | B12 | B13 | B14 | B15 | B16 | B17 | B18 | B19
    | B20 | B21 | B22 | B23 | B24 | B25 | B26 | B27 | B28 | B29 | B30 | B31 | B32 | B33 | B34 | B35 | B36 | B37 | B38 | B39
    where
        derive succ, pred, enumerate, minValue, maxValue


walk : a -> List a
    where
        a has succ : a -> Maybe a
walk x =
    walkWith succ x


walkBack : a -> List a
    where
        a has maxValue : a
        a has pred : a -> Maybe a
walkBack _ =
    walkWith pred maxValue


count : a -> Int
    where
        a has enumerate : List a
count _ =
    List.length enumerate


bounds : a -> ( a, a )
    where
        a has minValue : a
        a has maxValue : a
bounds _ =
    ( minValue, maxValue )


boundsText : a -> String
    where
        a has minValue : a
        a has maxValue : a
        a has toString : a -> String
boundsText _ =
    toString minValue ++ ".." ++ toString maxValue


walkWith : (a -> Maybe a) -> a -> List a
walkWith step x =
    case step x of
        Just y ->
            x :: walkWith step y

        Nothing ->
            [ x ]


phantomEnum : List (Phantom Int)
phantomEnum =
    Phantom.enumerate


phantomStart : Phantom String
phantomStart =
    Phantom.minValue


lines : List String
lines =
    [ Debug.toString ( Color.enumerate, List.map Color.succ Color.enumerate, List.map Color.pred Color.enumerate )
    , Debug.toString ( ( Color.minValue, Color.maxValue ), walkWith Color.succ Color.minValue == Color.enumerate, List.reverse (walkWith Color.pred Color.maxValue) == Color.enumerate )
    , Debug.toString ( List.sortWith Color.compare (List.reverse Color.enumerate) == Color.enumerate, List.map (\c -> ( c, Color.succ c )) [ Blue, Red ] )
    , Debug.toString ( phantomEnum, ( Phantom.succ phantomStart, Phantom.pred phantomStart ), walkWith Phantom.succ phantomStart )
    , Debug.toString ( ( One.enumerate, One.succ One, One.pred One ), ( One.minValue, One.maxValue ) )
    , Debug.toString ( List.length Big.enumerate, walkWith Big.succ Big.minValue == Big.enumerate, ( Big.maxValue, Big.pred Big.maxValue, Big.succ Big.maxValue ) )
    , Debug.toString ( ( walk False, walk LT, walk Red ), ( count True, count EQ, count Red ) )
    , Debug.toString ( bounds True, bounds GT, bounds Green )
    , Debug.toString ( walkBack True, walkBack GT )
    , String.join " " [ boundsText 0, boundsText (Int8.fromInt 0), boundsText (Int16.fromInt 0), boundsText (Int32.fromInt 0), boundsText (Word8.fromInt 0), boundsText (Word16.fromInt 0), boundsText (Word32.fromInt 0), boundsText (Word64.fromInt 0) ]
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
