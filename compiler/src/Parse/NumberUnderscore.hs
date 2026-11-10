{-# LANGUAGE BangPatterns, MagicHash #-}
module Parse.NumberUnderscore
  ( Result(..)
  , rescan
  )
  where


-- Ficcus (syntax track E5): underscores inside numeric literals, `1_000_000`, `0xFF_FF`, `1_000.000_1`, `1e1_0`.
--
-- Rule (docs/Ficcus-Design-Decisions.md, 7 Nov): an underscore, or a run of them, is allowed only between two digits of the
-- same digit run (decimal digits, or hexadecimal digits after `0x`), also in the fraction and the exponent. Not allowed at the
-- start, at the end, or next to `.`, `e`, a sign or the `0x` prefix. The value is that of the literal without the underscores.
--
-- `Parse.Number` runs its own scanner first (unchanged, so that every program without underscores is read exactly as before,
-- byte for byte); only when that scanner stops at an underscore does it call `rescan` on the same literal.


import Data.Char (chr)
import qualified Data.Utf8 as Utf8
import Data.Word (Word8)

import Foreign.Storable (peekByteOff)
import GHC.Exts (Addr#, Ptr(..))
import System.IO.Unsafe (unsafeDupablePerformIO)

import qualified Reporting.Error.Syntax as E
import qualified Elm.Float as EF



data Result
  = OkInt !Int Integer          -- number of bytes read, value
  | OkFloat !Int EF.Float       -- number of bytes read, the literal without its underscores
  | Err !Int E.Number           -- offset of the problem


-- | the literal that starts at the address, in `len` readable bytes
rescan :: Addr# -> Int -> Result
rescan addr len =
  let
    byte i = if i < len then unsafeDupablePerformIO (peekByteOff (Ptr addr) i :: IO Word8) else 0
    isDec w = w >= 0x30 && w <= 0x39
    isHex w = isDec w || (w >= 0x61 && w <= 0x66) || (w >= 0x41 && w <= 0x46)

    -- digits (and the underscores between them) from `i`, whose first byte is a digit: the digits read, the next offset
    run isDigit i0 =
      let
        go acc i =
          let w = byte i in
          if i < len && isDigit w then go (w : acc) (i + 1)
          else if i < len && w == 0x5F then
            let j = skip i in
            if j < len && isDigit (byte j) then go acc j else Left i
          else Right (reverse acc, i)
        skip i = if i < len && byte i == 0x5F then skip (i + 1) else i
      in
      go [] i0

    value base = foldl (\acc w -> base * acc + digitValue w) 0
    digitValue w
      | w <= 0x39 = fromIntegral w - 0x30
      | w >= 0x61 = fromIntegral w - 0x61 + 10
      | otherwise = fromIntegral w - 0x41 + 10

    -- the end of a literal: it must not run into a name
    finish i ok = if i < len && isNameByte (byte i) then Err i E.NumberEnd else ok i

    isNameByte w = isDec w || (w >= 0x61 && w <= 0x7A) || (w >= 0x41 && w <= 0x5A) || w == 0x5F || w >= 0x80
  in
  if byte 0 == 0x30 && (byte 1 == 0x78)
  then
    -- hexadecimal
    if not (isHex (byte 2)) then Err 2 E.NumberHexDigit
    else
      case run isHex 2 of
        Left i -> Err i E.NumberUnderscore
        Right (ds, i) -> finish i (\k -> OkInt k (value 16 ds))
  else
    case run isDec 0 of
      Left i -> Err i E.NumberUnderscore
      Right (ds, i1) ->
        if length ds > 1 && take 1 ds == [0x30] then Err 1 E.NumberNoLeadingZero
        else if byte 0 == 0x30 && byte i1 == 0x5F then Err 1 E.NumberNoLeadingZero
        else
          let
            n = value 10 ds
            exponentFrom i0 =
              -- after `e`: an optional sign, then digits
              let
                i = if byte i0 == 0x2B || byte i0 == 0x2D then i0 + 1 else i0
              in
              if not (isDec (byte i)) then Err i0 E.NumberEnd
              else
                case run isDec i of
                  Left j -> Err j E.NumberUnderscore
                  Right (_, j) -> finish j (\k -> OkFloat k (Utf8.fromChars (literal k)))
            literal k = [ chr (fromIntegral w) | j <- [0 .. k - 1], let w = byte j, w /= 0x5F ]
          in
          if i1 < len && byte i1 == 0x2E
          then
            if not (isDec (byte (i1 + 1))) then Err i1 (E.NumberDot n)
            else
              case run isDec (i1 + 1) of
                Left j -> Err j E.NumberUnderscore
                Right (_, j) ->
                  if j < len && (byte j == 0x65 || byte j == 0x45) then exponentFrom (j + 1)
                  else finish j (\k -> OkFloat k (Utf8.fromChars (literal k)))
          else if i1 < len && (byte i1 == 0x65 || byte i1 == 0x45)
          then exponentFrom (i1 + 1)
          else finish i1 (\k -> OkInt k n)
