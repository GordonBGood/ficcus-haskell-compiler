{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE MagicHash #-}
-- Ficcus (A4c, docs/A4-DERIVE-DESIGN.md section 2): the bodies of the derived enumeration members (group E), written as
-- source so that canonicalization, the type checker and the specializer treat them like the program's own code.  Only an
-- enumeration (every constructor without fields; Canonicalize.Derive refuses the others) gets them:
--
--   minValue = C1          maxValue = Cn          enumerate = [ C1, ..., Cn ]
--   succ x = case x of C1 -> Maybe.Just C2; ...; Cn -> Maybe.Nothing
--   pred x = case x of C1 -> Maybe.Nothing; C2 -> Maybe.Just C1; ...
--
-- Declaration order, consistent with the derived `compare`.  The type recorder keys a node by its region and kind, so every
-- generated node gets its own region: the region of the member in the `derive` line, its end moved by a running count
-- (from 1000 on, apart from the hidden patterns of Canonicalize.Derive, which start at 1).
module Canonicalize.DeriveEnum
  ( body
  )
  where


import GHC.Exts (Int(I#), int2Word#, plusWord64#, wordToWord64#)

import qualified AST.Prim.Module as Module
import qualified AST.Prim.Name as N
import qualified AST.Source as Src
import qualified Reporting.Annotation as A
import qualified String as S


-- | the parameters and the body of the enumeration member `member` of a type with these constructors (in declaration order)
body :: A.Region -> String -> [N.Name] -> ([Src.Pattern], Src.Expr)
body r member ctors =
  case member of
    "minValue" -> ([], ctor 1 (head ctors))
    "maxValue" -> ([], ctor 2 (last ctors))
    "enumerate" -> ([], at 3 (Src.List [ ctor (10 + i) c | (i, c) <- zip [0 ..] ctors ]))
    "succ" -> step (zip ctors (map Just (drop 1 ctors) ++ [Nothing]))
    "pred" -> step (zip ctors (Nothing : map Just ctors))
    _ -> ([], at 4 Src.Unit)     -- (not reached: Derive.isEnumMember)
  where
    n = length ctors
    at :: Int -> a -> A.Located a
    at i = A.At (widen (1000 + i) r)
    ctor i c = at i (Src.Var Src.CapVar c)
    maybeCtor i name = at i (Src.VarQual Src.CapVar (Module.toPrefix (Module.fromString (S.fromChars "Maybe"))) (N.fromString (S.fromChars name)))
    x = N.fromString (S.fromChars "x")
    -- the k-th branch uses the counts base, base+1, base+2, base+3
    step pairs =
      ( [at 5 (Src.PVar x)]
      , at 6 (Src.Case (at 7 (Src.Var Src.LowVar x))
          [ (at (base k) (Src.PCtor (widen (1000 + base k + 1) r) c []), result k next)
          | (k, (c, next)) <- zip [0 ..] pairs ])
      )
    base k = 10 + n + 4 * k
    result k next =
      case next of
        Nothing -> maybeCtor (base k + 2) "Nothing"
        Just c -> at (base k + 3) (Src.Call (maybeCtor (base k + 2) "Just") [ctor (base k + 3 + 4 * n + 100) c])


widen :: Int -> A.Region -> A.Region
widen (I# k) (A.Region s e) =
  A.Region s (plusWord64# e (wordToWord64# (int2Word# k)))
