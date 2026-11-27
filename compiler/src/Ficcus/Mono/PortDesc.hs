{-# OPTIONS_GHC -Wall #-}
module Ficcus.Mono.PortDesc
  ( portDesc
  , elmTypeText
  , jsonShape
  , flagsKeyPart
  , flagsOfKey
  , isUnitFlags
  , cString
  )
  where


-- Ficcus, effects slices E3a and E3b (docs/E3-PORTS-DESIGN.md D2, D7, D11): what the C side needs to know about a port's or the
-- flags' type besides the generated converters.
--
-- * `portDesc`: the description of the type that runtime/fic_ports.h `fic_pd_explain` walks when a value is refused, to build the
--   Error that Elm's decoder (Optimize.Port.toDecoder) gives: i Int, f Float, b Bool, s String, v Json.Value, u (), m Maybe, l List,
--   a Array, t<n> a tuple, r<n>:<name>=<type>.. a record. The fields of a record are in the order Elm's decoder tries them: the reverse
--   of Map.toList over the field names (AST Name order: length, then bytes), since `decodeRecord` folds `fieldAndThen` over that list
--   and the last field becomes the outermost decoder (checked on elm0193: `{name, age, xs}` reports `name` first).
-- * `elmTypeText`, `jsonShape`: the comment lines of the generated `<Module>_ports.h`.
-- * The flags type travels in the key of `main`'s worker kernel (Spec.specWorker) as one more part, only when it is not `()`, so a
--   program with () flags is unchanged.


import qualified Data.Bits as Bits
import qualified Data.Char as Char
import qualified Data.List as List

import Ficcus.Mono.Class (Key(..), KeyPart(..), MType(..))


-- | the description of a port payload or flags type, or Nothing when it is not one Elm allows (Array included)
portDesc :: MType -> Maybe String
portDesc t =
  case t of
    TyCon "elm/core:Basics.Int" [] -> Just "i"
    TyCon "elm/core:Basics.Float" [] -> Just "f"
    TyCon "elm/core:Basics.Bool" [] -> Just "b"
    TyCon "elm/core:String.String" [] -> Just "s"
    TyCon "elm/json:Json.Encode.Value" [] -> Just "v"
    TyCon "elm/json:Json.Decode.Value" [] -> Just "v"
    TyUnit -> Just "u"
    TyCon "elm/core:Maybe.Maybe" [e] -> ('m' :) <$> portDesc e
    TyCon "elm/core:List.List" [e] -> ('l' :) <$> portDesc e
    TyCon "elm/core:Array.Array" [e] -> ('a' :) <$> portDesc e
    TyTuple ts | length ts `elem` [2, 3] -> (\ds -> 't' : show (length ts) ++ concat ds) <$> mapM portDesc ts
    TyRecord fs ->
      do  ds <- mapM (\(n, ft) -> (\d -> n ++ "=" ++ d) <$> portDesc ft) (decodeOrder fs)
          return ("r" ++ show (length fs) ++ ":" ++ concat ds)
    _ -> Nothing
  where
    decodeOrder fs = reverse (List.sortOn (\(n, _) -> (length (utf8 n), utf8 n)) fs)


-- | the type as Elm writes it (unqualified names)
elmTypeText :: MType -> String
elmTypeText = go False
  where
    go nested t =
      case t of
        TyCon n [] -> base n
        TyCon n args -> paren nested (unwords (base n : map (go True) args))
        TyFun a b -> paren nested (go True a ++ " -> " ++ go False b)
        TyRecord fs -> "{ " ++ List.intercalate ", " [ f ++ " : " ++ go False x | (f, x) <- fs ] ++ " }"
        TyTuple xs -> "( " ++ List.intercalate ", " (map (go False) xs) ++ " )"
        TyUnit -> "()"
    base n = reverse (takeWhile (/= '.') (reverse n))
    paren b s = if b then "(" ++ s ++ ")" else s


-- | the JSON a host sends or receives (an outgoing record's fields in Elm's order, length then bytes)
jsonShape :: MType -> String
jsonShape t =
  case t of
    TyCon "elm/core:Basics.Int" [] -> "int"
    TyCon "elm/core:Basics.Float" [] -> "number"
    TyCon "elm/core:Basics.Bool" [] -> "true|false"
    TyCon "elm/core:String.String" [] -> "string"
    TyCon "elm/json:Json.Encode.Value" [] -> "any"
    TyCon "elm/json:Json.Decode.Value" [] -> "any"
    TyUnit -> "null"
    TyCon "elm/core:Maybe.Maybe" [e] -> jsonShape e ++ "|null"
    TyCon "elm/core:List.List" [e] -> "[" ++ jsonShape e ++ ", ...]"
    TyCon "elm/core:Array.Array" [e] -> "[" ++ jsonShape e ++ ", ...]"
    TyTuple xs -> "[" ++ List.intercalate ", " (map jsonShape xs) ++ "]"
    TyRecord fs -> "{" ++ List.intercalate ", " [ show' f ++ ": " ++ jsonShape x | (f, x) <- List.sortOn (\(n, _) -> (length (utf8 n), utf8 n)) fs ] ++ "}"
    _ -> "?"
  where
    show' f = "\"" ++ f ++ "\""


-- | the part of the worker kernel's key that carries the flags type (a wrapper that no Elm type has)
flagsKeyPart :: MType -> KeyPart
flagsKeyPart t = ByType (TyCon flagsMarker [t])


-- | the flags type, when the worker's key carries one (flags other than `()`)
flagsOfKey :: Key -> Maybe MType
flagsOfKey (Key parts) =
  case [ t | ByType (TyCon m [t]) <- parts, m == flagsMarker ] of
    t : _ -> Just t
    [] -> Nothing


flagsMarker :: String
flagsMarker = "ficcus:flags"


isUnitFlags :: MType -> Bool
isUnitFlags t = case t of { TyUnit -> True; _ -> False }


-- | a C string literal of a text (UTF-8; every byte outside printable ASCII, the quote and the backslash as a 3 digit octal escape)
cString :: String -> String
cString s = "\"" ++ concatMap byte (concatMap encode s) ++ "\""
  where
    byte b
      | b >= 32 && b < 127 && b /= 34 && b /= 92 && b /= 63 = [Char.chr b]
      | otherwise = '\\' : octal b
    octal b = [Char.intToDigit (b `div` 64), Char.intToDigit ((b `div` 8) `mod` 8), Char.intToDigit (b `mod` 8)]
    encode = utf8Char


utf8 :: String -> [Int]
utf8 = concatMap utf8Char


utf8Char :: Char -> [Int]
utf8Char ch
  | c < 0x80 = [c]
  | c < 0x800 = [0xC0 Bits..|. (c `Bits.shiftR` 6), cont c]
  | c < 0x10000 = [0xE0 Bits..|. (c `Bits.shiftR` 12), cont (c `Bits.shiftR` 6), cont c]
  | otherwise = [0xF0 Bits..|. (c `Bits.shiftR` 18), cont (c `Bits.shiftR` 12), cont (c `Bits.shiftR` 6), cont c]
  where
    c = Char.ord ch
    cont x = 0x80 Bits..|. (x Bits..&. 0x3F)
