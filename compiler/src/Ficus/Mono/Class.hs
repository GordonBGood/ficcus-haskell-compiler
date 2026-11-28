{-# OPTIONS_GHC -Wall #-}
module Ficus.Mono.Class
  ( Class(..)
  , AppClass(..)
  , MType(..)
  , KeyPart(..)
  , Key(..)
  , classText
  , mtypeText
  , keyPartText
  , keyText
  , mangle
  )
  where


-- Ficus, stage (iii): representation classes and specialization keys (docs/STAGE3-PLAN.md, section 2.1).
--
-- A class says how a value is held, nothing more. A key says, for each quantified variable of a
-- definition, what the specialized copy depends on: the class of the instance (unconstrained variable),
-- its exact type (number, comparable, equatable, printed), the appendable class (string or list of an
-- element class) or, for a row variable, the layout of the record it stands for.


import qualified Data.List as List


data Class
  = CI64 | CF64 | CU32 | CEnum | CUnit | CRef
  | CStruct [Class]            -- ordered field classes (the logical layout); never the class of an unconstrained variable
  deriving (Eq, Ord, Show)


data AppClass
  = AStr
  | AList Class
  deriving (Eq, Ord, Show)


-- | a type without variables, aliases removed, record fields in alphabetical order
data MType
  = TyCon String [MType]        -- home module id and name, arguments
  | TyFun MType MType
  | TyRecord [(String, MType)]
  | TyTuple [MType]
  | TyUnit
  deriving (Eq, Ord, Show)


data KeyPart
  = ByClass Class
  | ByType MType
  | ByApp AppClass
  | ByLayout [(String, Class)]
  deriving (Eq, Ord, Show)


-- | one part per quantified variable v0 .. vn of the scheme, in order
newtype Key = Key [KeyPart]
  deriving (Eq, Ord, Show)


classText :: Class -> String
classText c =
  case c of
    CI64 -> "i64"
    CF64 -> "f64"
    CU32 -> "u32"
    CEnum -> "enum"
    CUnit -> "unit"
    CRef -> "ref"
    CStruct fs -> "struct(" ++ List.intercalate "," (map classText fs) ++ ")"


mtypeText :: MType -> String
mtypeText t =
  case t of
    TyCon n [] -> n
    TyCon n args -> "(" ++ unwords (n : map mtypeText args) ++ ")"
    TyFun a b -> "(" ++ mtypeText a ++ " -> " ++ mtypeText b ++ ")"
    TyRecord fs -> "{" ++ List.intercalate ", " [ n ++ ":" ++ mtypeText x | (n, x) <- fs ] ++ "}"
    TyTuple xs -> "(" ++ List.intercalate ", " (map mtypeText xs) ++ ")"
    TyUnit -> "()"


keyPartText :: KeyPart -> String
keyPartText p =
  case p of
    ByClass c -> classText c
    ByType t -> "type " ++ mtypeText t
    ByApp AStr -> "app string"
    ByApp (AList c) -> "app list " ++ classText c
    ByLayout fs -> "layout {" ++ List.intercalate ", " [ n ++ ":" ++ classText c | (n, c) <- fs ] ++ "}"


keyText :: Key -> String
keyText (Key parts) =
  "(" ++ List.intercalate "; " (zipWith (\i p -> "v" ++ show (i :: Int) ++ "=" ++ keyPartText p) [0 ..] parts) ++ ")"


-- | a C identifier suffix for a key: `__` and the parts; exact types are not spelled (a counter names them)
mangle :: Key -> String
mangle (Key parts) =
  concatMap (\p -> "__" ++ part p) parts
  where
    part p =
      case p of
        ByClass c -> cls c
        ByType _ -> "t"
        ByApp AStr -> "s"
        ByApp (AList c) -> "l" ++ cls c
        ByLayout fs -> "r" ++ concatMap (cls . snd) fs
    cls c =
      case c of
        CI64 -> "i"
        CF64 -> "d"
        CU32 -> "c"
        CEnum -> "e"
        CUnit -> "u"
        CRef -> "p"
        CStruct fs -> "S" ++ concatMap cls fs ++ "E"
