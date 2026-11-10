{-# OPTIONS_GHC -Wall #-}
module Ficcus.Mono.Layout
  ( classType
  , classTag
  , leavesOf
  , nptrOf
  , objType
  , objectDef
  , objectDefWith
  , fieldRead
  , memberOf
  , fieldStores
  , leafPaths
  , refPaths
  )
  where


-- Ficcus, stage (iv) slice S0 (docs/STAGE4-PLAN.md, 2.3 and the amendment of rev 113): the layout of heap objects.
--
-- A heap object is  { header; reference words; scalar words }.  A field whose class is a struct (a tuple or a record) is
-- *flattened*: its leaves (the non-struct classes, in declaration order, depth first) go among the object's words, the
-- reference leaves first. So the generic drop needs no type information: the header's `nptr` is the number of reference
-- leaves and they are the first words after the header (after the code pointer for a closure).
--
-- Leaves are named r0, r1, ... (references) and s0, s1, ... (scalars) in the order of the field list. A struct is rebuilt
-- from its leaves when a field is read, and taken apart into its leaves when a field is stored.


import qualified Data.List as List

import Ficcus.Mono.Class (Class(..))


classType :: Class -> String
classType c =
  case c of
    CI64 -> "int64_t"
    CF64 -> "double"
    CU32 -> "uint32_t"
    CEnum -> "uint8_t"
    CUnit -> "uint8_t"
    CRef -> "fic_ref"
    CStruct fs -> "fic_s_" ++ concatMap classTag fs


classTag :: Class -> String
classTag c =
  case c of
    CI64 -> "i"
    CF64 -> "d"
    CU32 -> "c"
    CEnum -> "e"
    CUnit -> "u"
    CRef -> "p"
    CStruct fs -> "S" ++ concatMap classTag fs ++ "E"


-- the non-struct classes of a class, in declaration order
leavesOf :: Class -> [Class]
leavesOf c =
  case c of
    CStruct fs -> concatMap leavesOf fs
    _ -> [c]


-- the number of reference leaves of a field list
nptrOf :: [Class] -> Int
nptrOf cs = length [ () | CRef <- concatMap leavesOf cs ]


-- the member names of the leaves of each field
leafNames :: [Class] -> [[String]]
leafNames cs = go 0 0 cs
  where
    go :: Int -> Int -> [Class] -> [[String]]
    go _ _ [] = []
    go nr ns (c : rest) =
      let (names, nr', ns') = foldl step ([], nr, ns) (leavesOf c)
      in reverse names : go nr' ns' rest
    step (acc, nr, ns) leaf =
      case leaf of
        CRef -> (("r" ++ show nr) : acc, nr + 1, ns)
        _ -> (("s" ++ show ns) : acc, nr, ns + 1)


objType :: [Class] -> String
objType cs = "fic_o_" ++ concatMap classTag cs


-- the C type of a constructor object (a list cell, a boxed struct, ...): header, references, scalars
objectDef :: [Class] -> String
objectDef cs = objectDefWith "" (objType cs) cs


-- the same with extra members after the header (the code pointer of a closure) and a type name
objectDefWith :: String -> String -> [Class] -> String
objectDefWith extra name cs =
  "typedef struct { fic_hdr h; " ++ extra
  ++ concat [ classType c ++ " " ++ n ++ "; " | (c, n) <- members, c == CRef ]
  ++ concat [ classType c ++ " " ++ n ++ "; " | (c, n) <- members, c /= CRef ]
  ++ "} " ++ name ++ ";"
  where members = zip (concatMap leavesOf cs) (concat (leafNames cs))


-- the value of field i of the object `p` (an expression of a pointer type to the object's struct); a struct field is
-- rebuilt from its leaves (`p` may be evaluated several times: pass a pure expression)
fieldRead :: (Class -> String) -> [Class] -> Int -> String -> String
fieldRead typeOf cs i p =
  case cs !! i of
    c@(CStruct _) -> "(" ++ typeOf c ++ ")" ++ build c [ p ++ "->" ++ n | n <- names ]
    _ -> p ++ "->" ++ head' names
  where
    names = leafNames cs !! i
    head' ns = case ns of { n : _ -> n; [] -> "r0" }
    -- nested braces for the struct members of a struct
    build c ns = "{ " ++ fst (inner c ns) ++ " }"
    inner c ns =
      case c of
        CStruct fs -> let (parts, rest) = parts' fs ns in (List.intercalate ", " parts, rest)
        _ -> (head' ns, drop 1 ns)
    parts' [] ns = ([], ns)
    parts' (f : fs) ns =
      let (txt, rest) = case f of
                          CStruct _ -> let (t, r) = inner f ns in ("{ " ++ t ++ " }", r)
                          _ -> inner f ns
          (more, rest') = parts' fs rest
      in (txt : more, rest')


-- the member name of field i when it is not a struct
memberOf :: [Class] -> Int -> String
memberOf cs i = case leafNames cs !! i of { n : _ -> n; [] -> "r0" }


-- the statements that store the value `v` (a variable) in field i of the object `p`
fieldStores :: [Class] -> Int -> String -> String -> [String]
fieldStores cs i p v =
  [ p ++ "->" ++ n ++ " = " ++ path ++ ";" | (n, path) <- zip (leafNames cs !! i) (leafPaths (cs !! i) v) ]


-- the leaves of the struct value `v` as C member paths
leafPaths :: Class -> String -> [String]
leafPaths c v =
  case c of
    CStruct fs -> concat [ leafPaths f (v ++ ".f" ++ show k) | (k, f) <- zip [0 :: Int ..] fs ]
    _ -> [v]


-- the C paths of the reference leaves of the value `v` of class `c` (a struct holds one count on each of them)
refPaths :: Class -> String -> [String]
refPaths c v =
  case c of
    CStruct fs -> concat [ refPaths f (v ++ ".f" ++ show k) | (k, f) <- zip [0 :: Int ..] fs ]
    CRef -> [v]
    _ -> []
