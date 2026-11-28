{-# OPTIONS_GHC -Wall #-}
module Ficcus.Mono.PortFic
  ( sizedOf
  , vectorElem
  , rawElem
  , sizedDescChar
  , sizedEncode
  , sizedDecode
  , sizedShape
  )
  where


-- Ficcus, effects slices E3c and E3d (docs/E3-PORTS-DESIGN.md D5, D6, D9, D10): the pieces of the port converters for the payload
-- types of Ficcus (the sized integers, `Float32`, `Vector`), as text; the C functions they call are in runtime/fic_ports_fic.h.
--
-- * A sized integer crosses as a JSON integer (a `Word64` above 2^63 - 1 as the JUINT node of D5); incoming, the range of the type
--   is checked (a value outside it is a decode failure, never wrapped). `Float32` crosses as its Float (double) value; incoming, any
--   number, rounded to the nearest Float32 (out of range: an infinity, not a failure).
-- * A `Vector` of a fixed width number (`Int`, `Float`, a sized type) crosses as a raw vector node (D9; `rawElem` is its element
--   kind); every other `Vector` as a JSON array, like an `Array`. Incoming, a Vector also takes a JSON array of its elements.
-- * The description characters of `fic_pd_explain` (Ficcus.Mono.PortDesc): c h n Int8 Int16 Int32, C H N Word8 Word16 Word32,
--   W Word64, g Float32, V<T> Vector.


import Ficcus.Mono.Class (MType(..))
import qualified Ficcus.Mono.Sized as Sized
import Ficcus.Mono.Sized (Sized(..))


-- | the sized type of a payload type (the overlay's: Canonicalize.FicPayload, the only gate, refuses a project's own `Int8` or
-- `Vector` with Elm's payload error, so the ids alone suffice here)
sizedOf :: MType -> Maybe Sized
sizedOf t =
  case t of
    TyCon n [] -> Sized.sizedOfTypeId n
    _ -> Nothing


-- | the element type of a `Vector`
vectorElem :: MType -> Maybe MType
vectorElem t =
  case t of
    TyCon "author/project:Vector.Vector" [e] -> Just e
    _ -> Nothing


-- | the element kind (runtime/fic_ports_api.h `enum fic_el`) of a Vector element type that crosses raw
rawElem :: MType -> Maybe String
rawElem e =
  case e of
    TyCon "elm/core:Basics.Int" [] -> Just "FIC_EL_I64"
    TyCon "elm/core:Basics.Float" [] -> Just "FIC_EL_F64"
    _ ->
      do  s <- sizedOf e
          return $
            case s of
              I8 -> "FIC_EL_I8"; I16 -> "FIC_EL_I16"; I32 -> "FIC_EL_I32"
              U8 -> "FIC_EL_U8"; U16 -> "FIC_EL_U16"; U32 -> "FIC_EL_U32"; U64 -> "FIC_EL_U64"
              F32 -> "FIC_EL_F32"


sizedDescChar :: Sized -> Char
sizedDescChar s =
  case s of
    I8 -> 'c'; I16 -> 'h'; I32 -> 'n'
    U8 -> 'C'; U16 -> 'H'; U32 -> 'N'; U64 -> 'W'
    F32 -> 'g'


-- | the JSON of a value (a C expression of its class: int64_t, or double for Float32): an owned node
sizedEncode :: Sized -> String -> String
sizedEncode s v =
  case s of
    U64 -> "fic_pv_u64_out(" ++ v ++ ")"
    F32 -> "fic_json_float(" ++ v ++ ")"
    _ -> "fic_json_int(" ++ v ++ ")"


-- | the body of the decoder `static int f(fic_ref j, <class> *out)`
sizedDecode :: Sized -> String
sizedDecode s =
  case s of
    U64 -> "return fic_pv_u64_in(j, out);"
    F32 -> "return fic_pv_f32_in(j, out);"
    _ -> "return fic_pv_int_in(j, '" ++ [sizedDescChar s] ++ "', out);"


-- | the JSON shape for the comment of the generated `<Module>_ports.h`
sizedShape :: Sized -> String
sizedShape s =
  case s of
    I8 -> "int (-128 to 127)"
    I16 -> "int (-32768 to 32767)"
    I32 -> "int (-2147483648 to 2147483647)"
    U8 -> "int (0 to 255)"
    U16 -> "int (0 to 65535)"
    U32 -> "int (0 to 4294967295)"
    U64 -> "int (0 to 18446744073709551615)"
    F32 -> "number (rounded to Float32)"
