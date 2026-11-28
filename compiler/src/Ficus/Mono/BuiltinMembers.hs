{-# OPTIONS_GHC -Wall #-}
-- Ficus (A4c, docs/A4-DERIVE-DESIGN.md section 2, docs/attach/A4C-NOTES.md): the A4c members of the built-in types.
--
--   toString:  at every type Debug.toString can show, and for a derived `T$$toString` at its exact type, the kernel
--     `Debug.toString` at the key `[ByType t]`: the C generator's `showStmt`, which prints Elm's format (structural all the way
--     down: a written `toString` of a part is not called, decision 4 of the note).
--   the enumeration members:  `Bool` and `Order` have `minValue`, `maxValue`, `succ`, `pred`, `enumerate` (declaration
--     order, False < True as A4b's `compare`); `Int` and the sized integers have `minValue` and `maxValue`.  Each is a
--     definition of the overlay (FicOverlay for Bool, Order and Int; the sized modules' own top level `minValue`/`maxValue`).
module Ficus.Mono.BuiltinMembers
  ( toStringKernelId
  , enumMemberDef
  , isEnumMember
  )
  where


import Ficus.Mono.Class (MType(..))
import Ficus.Mono.Overlay (overlayModuleName)


-- | the kernel that is `toString` (built in, or derived) at an exact type
toStringKernelId :: String
toStringKernelId =
  "elm/core:Debug.toString"


isEnumMember :: String -> Bool
isEnumMember member =
  member `elem` ["minValue", "maxValue", "succ", "pred", "enumerate"]


-- | the definition (by its id) that is the enumeration member `member` of the built-in type `t`
enumMemberDef :: MType -> String -> Maybe String
enumMemberDef t member =
  case t of
    TyCon tid [] ->
      case lookup tid owners of
        Just (prefix, members) | member `elem` members -> Just (prefix ++ capital member)
        _ ->
          case [ s | s <- sizedInts, tid == "author/project:" ++ s ++ "." ++ s ] of
            s : _ | member `elem` bounds -> Just ("author/project:" ++ s ++ "." ++ member)
            _ -> Nothing
    _ ->
      Nothing
  where
    overlay n = "author/project:" ++ overlayModuleName ++ "." ++ n
    all5 = ["minValue", "maxValue", "succ", "pred", "enumerate"]
    bounds = ["minValue", "maxValue"]
    owners =
      [ ("elm/core:Basics.Bool", (overlay "ficBool", all5))
      , ("elm/core:Basics.Order", (overlay "ficOrder", all5))
      , ("elm/core:Basics.Int", (overlay "ficInt", bounds))
      ]
    sizedInts = ["Int8", "Int16", "Int32", "Word8", "Word16", "Word32", "Word64"]
    capital m =
      case m of
        c : rest -> toEnum (fromEnum c - 32) : rest
        [] -> []
