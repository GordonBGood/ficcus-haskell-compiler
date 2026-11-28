{-# LANGUAGE BangPatterns, ExtendedLiterals, MagicHash #-}
module AST.Prim.Variable
  ( chompUpper
  , chompLower
  , chompInner
  )
  where


import qualified Data.Char as Char
import GHC.Base (Char(C#))
import GHC.Exts (isTrue#)
import GHC.Prim

import qualified Bytes
import qualified Literals



-- CHOMPERS


{-# INLINE chompUpper #-}
{-# INLINE chompLower #-}
{-# INLINE chompInner #-}

chompUpper :: Addr# -> Addr# -> Word8# -> Addr#
chompLower :: Addr# -> Addr# -> Word8# -> Addr#
chompInner :: Addr# -> Addr# -> Word8# -> Addr#

chompUpper = chomp isUpper Char.isUpper
chompLower = chomp isLower Char.isLower
chompInner pos end w =
  if isTrue# (eqWord8# w 0x27#Word8 {-'-})
  then
    -- Ficus (track E4): `x'` is one name. As in Elm 0.19.3, a quote that starts a character
    -- literal (`f'a'`, `f'\n'`) still ends the name.
    if charLiteralAt pos end then pos else plusAddr# pos 1#
  else
    chomp isInner Char.isAlpha pos end w


-- | Does a character literal, `'a'` or `'\n'` or `'\u{1F600}'`, start at the quote at `pos`?
charLiteralAt :: Addr# -> Addr# -> Bool
charLiteralAt pos end =
  let
    byteAt n = if isTrue# (ltAddr# (plusAddr# pos n) end) then getWord8# pos n else 0##
    quote = 0x27##
    b1 = byteAt 1#
    hexRun n k =
      let b = byteAt n in
      if isTrue# (isHex b) then hexRun (n +# 1#) (k +# 1#)
      else isTrue# (k ># 0#) && isTrue# (eqWord# b 0x7D##) && isTrue# (eqWord# (byteAt (n +# 1#)) quote)
    isHex b =
      (leWord# 0x30## b `andI#` leWord# b 0x39##)
      `orI#` (leWord# 0x61## b `andI#` leWord# b 0x66##)
      `orI#` (leWord# 0x41## b `andI#` leWord# b 0x46##)
  in
  if isTrue# (eqWord# b1 0x5C##)
  then
    let b2 = byteAt 2# in
    if isTrue# (eqWord# b2 0x6E## `orI#` eqWord# b2 0x72## `orI#` eqWord# b2 0x74## `orI#` eqWord# b2 0x22##
                `orI#` eqWord# b2 quote `orI#` eqWord# b2 0x5C##)
    then isTrue# (eqWord# (byteAt 3#) quote)
    else if isTrue# (eqWord# b2 0x75##) && isTrue# (eqWord# (byteAt 3#) 0x7B##)
    then hexRun 4# 0#
    else False
  else if isTrue# (ltWord# b1 0x20##) || isTrue# (eqWord# b1 quote)
  then False
  else
    let
      len = if isTrue# (ltWord# b1 0x80##) then 1# else if isTrue# (ltWord# b1 0xE0##) then 2# else if isTrue# (ltWord# b1 0xF0##) then 3# else 4#
    in
    isTrue# (eqWord# (byteAt (1# +# len)) quote)



-- ASCII HELPERS


{-# INLINE isUpper #-}
{-# INLINE isLower #-}
{-# INLINE isDigit #-}
{-# INLINE isInner #-}

isUpper :: Word8# -> Bool
isLower :: Word8# -> Bool
isDigit :: Word8# -> Bool
isInner :: Word8# -> Bool

isUpper w = isTrue# (leWord8# 0x41#Word8 w) && isTrue# (leWord8# w 0x5A#Word8)
isLower w = isTrue# (leWord8# 0x61#Word8 w) && isTrue# (leWord8# w 0x7A#Word8)
isDigit w = isTrue# (leWord8# 0x30#Word8 w) && isTrue# (leWord8# w 0x39#Word8)
isInner w = isLower w || isUpper w || isDigit w || isTrue# (eqWord8# w 0x5F#Word8 {-_-})



-- CHOMP HELPER


{-# INLINE chomp #-}
chomp :: (Word8# -> Bool) -> (Char -> Bool) -> Addr# -> Addr# -> Word8# -> Addr#
chomp isGood# isGood pos end w
  | isGood# w                       = plusAddr# pos 1#
  | isTrue# (ltWord8# w 0xC0#Word8) = pos
  | isTrue# (ltWord8# w 0xE0#Word8) = chomp2 isGood pos end w
  | isTrue# (ltWord8# w 0xF0#Word8) = chomp3 isGood pos end w
  | isTrue# (ltWord8# w 0xF8#Word8) = chomp4 isGood pos end w
  | otherwise                       = pos


chomp2 :: (Char -> Bool) -> Addr# -> Addr# -> Word8# -> Addr#
chomp2 isGood pos end word =
  if isTrue# (leAddr# pos2 end) &&
  (
    let
      !w1 = word8ToWord# word
      !w2 = getWord8# pos 1#

      !c1 = uncheckedShiftL# (and# 0x3F## w1) 6#
      !c2 = and# 0x3F## w2
    in
    isTrue# (eqWord8# 0#Word8 (step table w2 (step table w1 0#Word8)))
    && isGood (C# (chr# (word2Int# (or# c1 c2))))
  )
    then pos2
    else pos
  where
    !pos2 = plusAddr# pos 2#
    !(Literals.FSM table) = Bytes.utf8_fsm


chomp3 :: (Char -> Bool) -> Addr# -> Addr# -> Word8# -> Addr#
chomp3 isGood pos end word =
  if isTrue# (leAddr# pos3 end) &&
  (
    let
      !w1 = word8ToWord# word
      !w2 = getWord8# pos 1#
      !w3 = getWord8# pos 2#

      !c1 = uncheckedShiftL# (and# 0x0F## w1) 12#
      !c2 = uncheckedShiftL# (and# 0x3F## w2) 6#
      !c3 = and# 0x3F## w3
    in
    isTrue# (eqWord8# 0#Word8 (step table w3 (step table w2 (step table w1 0#Word8))))
    &&
    isGood (C# (chr# (word2Int# (or# c1 (or# c2 c3)))))
  )
    then pos3
    else pos
  where
    !pos3 = plusAddr# pos 3#
    !(Literals.FSM table) = Bytes.utf8_fsm


chomp4 :: (Char -> Bool) -> Addr# -> Addr# -> Word8# -> Addr#
chomp4 isGood pos end word =
  if isTrue# (leAddr# pos4 end) &&
  (
    let
      !w1 = word8ToWord# word
      !w2 = getWord8# pos 1#
      !w3 = getWord8# pos 2#
      !w4 = getWord8# pos 3#

      !c1 = uncheckedShiftL# (and# 0x07## w1) 18#
      !c2 = uncheckedShiftL# (and# 0x3F## w2) 12#
      !c3 = uncheckedShiftL# (and# 0x3F## w3) 6#
      !c4 = and# 0x3F## w4
    in
    isTrue# (eqWord8# 0#Word8 (step table w4 (step table w3 (step table w2 (step table w1 0#Word8)))))
    &&
    isGood (C# (chr# (word2Int# (or# (or# c1 c2) (or# c3 c4)))))
  )
    then pos4
    else pos
  where
    !pos4 = plusAddr# pos 4#
    !(Literals.FSM table) = Bytes.utf8_fsm


{-# INLINE getWord8# #-}
getWord8# :: Addr# -> Int# -> Word#
getWord8# ba i =
  word8ToWord# (indexWord8OffAddr# ba i)


{-# INLINE step #-}
step :: Addr# -> Word# -> Word8# -> Word8#
step table word state =
  let
    !tran = indexInt8OffAddr# table (word2Int# word)
  in
  indexWord8OffAddr# table (256# +# word2Int# (word8ToWord# state) +# int8ToInt# tran)

