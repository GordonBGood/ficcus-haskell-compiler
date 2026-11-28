{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE PatternGuards #-}
-- Ficus (A4b, docs/A4-DERIVE-DESIGN.md section 2, docs/attach/A4B-NOTES.md): the derived `compare` and `hash`.
--
-- A derived member `T$$compare` (`T$$hash`) has the stub body of Canonicalize.Derive.  The specializer does not clone it: a
-- use at the exact type `T args` is the kernel `Basics.compare` (`hashKernelId`) at the key `[ByType (T args)]`, and the
-- type is recorded in `MProgram.mpDerived`.  The C generator then writes one helper per exact type (`fic_cmp_N`,
-- `fic_hash_N`), which walks the constructors in declaration order and the fields left to right, and calls the member
-- clone of a part that has a written member (A3b's table) or the helper of a part whose member is derived.
--
-- The orders of the built-in types (decisions of 25 Nov, rev 182): `Maybe` is `Nothing < Just` (elm/core declares `Just`
-- first), `Bool` is `False < True` (elm/core declares `True` first), `Result` and `Order` follow the declaration
-- (`Ok < Err`, `LT < EQ < GT`); records compare their fields in alphabetical order; `Array`, `Vector`, `List`, `Dict`
-- (as its ascending `toList`) and `Set` lexicographically.
module Ficus.Mono.Derived
  ( isDerivedStub
  , derivedKernel
  , hashKernelId
  , structuralMembers
  , fieldTypes
  , mtypeSource
  , derivedDepthLimit
  , nonRegularText
  , ctorRank
  , hashRuntime
  )
  where


import qualified Data.List as List
import qualified Data.Map.Strict as Map

import qualified AST.Canonical as Can
import qualified AST.Derive as Derive
import qualified AST.Prim.Module as Module
import qualified Reporting.Annotation as A
import qualified String

import Ficus.Mono.Class (MType(..))
import Ficus.Mono.Ir (UnionShape(..))
import Ficus.Mono.RowShape (substShape)


-- | the definition of a derived member: its body is the stub `Elm.Kernel.FicDerive.T.m`
isDerivedStub :: Can.Def -> Bool
isDerivedStub def =
  case def of
    Can.TypedDef _ _ _ (A.At _ (Can.VarKernel home _)) _ -> String.toChars (Module.kernelToString home) == Derive.kernelHome
    Can.Def _ _ (A.At _ (Can.VarKernel home _)) -> String.toChars (Module.kernelToString home) == Derive.kernelHome
    _ -> False


-- | the members whose derived form gets a C helper of its own (recorded in mpDerived; A4c's `toString` is the kernel
-- Debug.toString at the type)
structuralMembers :: [String]
structuralMembers =
  ["compare", "hash"]


-- | the kernel that stands for a derived member at an exact type, and its arity
derivedKernel :: String -> Maybe (String, Int)
derivedKernel member =
  case member of
    "compare" -> Just ("elm/core:Basics.compare", 2)
    "hash" -> Just (hashKernelId, 1)
    -- (A4c) Debug.toString at the exact type (no helper of its own: `showStmt`; not recorded in mpDerived)
    "toString" -> Just ("elm/core:Debug.toString", 1)
    _ -> Nothing


-- | the structural hash at the key's exact type (`hash` of the built-in types and the derived ones)
hashKernelId :: String
hashKernelId =
  "ficus:FicDerive.hash"


-- | the exact types of the parts of a type: the fields of every constructor of a custom type with the arguments put in,
-- the parts of tuples and records, the arguments of other types
fieldTypes :: Map.Map String UnionShape -> MType -> [MType]
fieldTypes unions t =
  case t of
    TyCon tid args
      | Just u <- Map.lookup tid unions -> [ subst args f | (_, _, fs) <- usCtors u, f <- fs ]
      | otherwise -> args
    TyTuple xs -> xs
    TyRecord fs -> map snd fs
    TyFun _ _ -> []
    TyUnit -> []
  where
    -- the parameters of a union are `TyCon "#i" []`
    subst = substShape


-- | an exact type as it is written in a program (`Nest (List Int)`), for messages (A3b review A3)
mtypeSource :: MType -> String
mtypeSource t =
  case t of
    TyCon tid [] -> short tid
    TyCon tid args -> unwords (short tid : map arg args)
    TyFun a b -> argFun a ++ " -> " ++ mtypeSource b
    TyTuple xs -> "( " ++ List.intercalate ", " (map mtypeSource xs) ++ " )"
    TyRecord [] -> "{}"
    TyRecord fs -> "{ " ++ List.intercalate ", " [ n ++ " : " ++ mtypeSource x | (n, x) <- fs ] ++ " }"
    TyUnit -> "()"
  where
    short tid = reverse (takeWhile (/= '.') (reverse tid))
    arg x =
      case x of
        TyCon _ (_ : _) -> "(" ++ mtypeSource x ++ ")"
        TyFun _ _ -> "(" ++ mtypeSource x ++ ")"
        _ -> mtypeSource x
    argFun x =
      case x of
        TyFun _ _ -> "(" ++ mtypeSource x ++ ")"
        _ -> mtypeSource x


-- | (A4bf, review M1) the most derived exact types nested in one another (a derived type in a field of a derived type, and so
-- on) that a derived `compare`/`hash` may reach: beyond it a type of the program keeps growing.  Smaller than A3's 2,000
-- distinct types of `membersInside`: each nested type is a new A3 walk over a type that grows by one level, so the work is
-- cubic in this depth (2,000 took 145 s; 200 takes well under a second), and no regular type nests derived types that deep.
derivedDepthLimit :: Int
derivedDepthLimit =
  200


-- | (A4bf, review M1) the report when the bound is reached: the outermost type as written, the type reached at the bound
nonRegularText :: String -> MType -> MType -> String
nonRegularText member outer reached =
  "the derived `" ++ member ++ "` of the type `" ++ mtypeSource outer ++ "` reaches more than " ++ show derivedDepthLimit
    ++ " nested types (" ++ shortened (mtypeSource reached) ++ "): a type in it is used at another argument inside itself"
    ++ " (non-regular recursion), which the C generator does not support"
  where
    shortened s = if length s > 60 then take 60 s ++ " ..." else s


-- | the place of a constructor (by its tag) in the order of `compare`: the declaration order, but for `Maybe` (Nothing first).
-- (`Bool` is not a constructor cell in C: the C generator compares it as 0 and 1, False first.)
ctorRank :: String -> Int -> Int
ctorRank tid tag
  | tid == "elm/core:Maybe.Maybe" = 1 - tag
  | otherwise = tag


-- | the run time of `hash` (decision of the A4 note, section 2): the splitmix64 finalizer as the mixer, `combine h x = mix (h *
-- 0x9E3779B97F4A7C15 + x)`, strings by FNV-1a 64 over their UTF-8 bytes.  Stable: no seed, the same on every platform and run.
hashRuntime :: String
hashRuntime =
  unlines
    [ "/* A4b: the derived hash (splitmix64 finalizer; FNV-1a 64 for strings; no seed) */"
    , "static inline uint64_t fic_hash_mix(uint64_t z) {"
    , "  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;"
    , "  z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;"
    , "  return z ^ (z >> 31);"
    , "}"
    , "static inline uint64_t fic_hash_combine(uint64_t h, uint64_t x) { return fic_hash_mix(h * 0x9E3779B97F4A7C15ULL + x); }"
    , "static inline uint64_t fic_hash_f64(double d) { uint64_t u; if (d == 0.0) d = 0.0; memcpy(&u, &d, sizeof u); return fic_hash_mix(u); }"
    , "static inline uint64_t fic_hash_bytes(const uint8_t *p, int64_t n) {"
    , "  uint64_t h = 0xCBF29CE484222325ULL; int64_t i;"
    , "  for (i = 0; i < n; i++) { h ^= p[i]; h *= 0x100000001B3ULL; }"
    , "  return fic_hash_mix(h);"
    , "}"
    ]
