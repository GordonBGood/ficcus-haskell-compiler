{-# LANGUAGE MagicHash #-}
-- Layout after a multi-line string (Ficus track E4, cases K-1947 and K-2155).
--
-- The column of the parser is the column of the next character, so after
--
--     someString =
--         """
--     """ ++ ""
--
-- the `++` is at column 5 although it continues an expression that starts at column 9, and the
-- indentation checks of the let and case layout reject the program (elm/compiler issues 1947 and
-- 2155). A multi-line string is one token: the text after it continues the line it started on.
-- So after such a string the column is taken as if the closing quotes were on the first line
-- (as far to the right as the opening quotes and their three characters), when that is further to the right
-- than the real column. The row stays the real one, so error positions are right, except for the rest of that line.
module Parse.StringLayout
  ( afterMultiline
  )
  where


import Data.Bits ((.&.), (.|.), shiftR)
import GHC.Word (Word64(W64#))

import Parse.Primitives (Cursor)


-- | the cursor at the start of the string, the cursor after its closing quotes: the cursor to continue with
afterMultiline :: Cursor -> Cursor -> Cursor
afterMultiline start end =
  let
    s = W64# start
    e = W64# end
    column w = w .&. 0xFFFFFFFF
  in
  if shiftR s 32 == shiftR e 32
  then end
  else
    case (e .&. 0xFFFFFFFF00000000) .|. max (column e) (column s + 3) of
      W64# result -> result
