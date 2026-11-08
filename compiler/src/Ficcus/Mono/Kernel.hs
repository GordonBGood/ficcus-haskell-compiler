{-# OPTIONS_GHC -Wall #-}
module Ficcus.Mono.Kernel
  ( kernelArity
  , forcedExact
  )
  where


-- Ficcus, stage (iii) slice 1: the kernel table (decision A2).
--
-- A callee in this table has no specialized Elm body: the specializer keeps the call as `MKernel id key`
-- and `Generate.C` maps it to a runtime function or an inline C operator by id and key. Every other callee
-- is an ordinary definition and is cloned from its Elm body. The table is a fixed list in the compiler,
-- not a recorder flag: the recorder cannot know which functions the runtime implements, the table is
-- needed anyway to lower the call, and an unknown `Elm.Kernel` reference in a body is reported by name.
-- It grows slice by slice (the 16 target programs give the first version).


-- | arity of a kernel function by callee id
kernelArity :: String -> Maybe Int
kernelArity cid =
  lookup cid
    [ ("elm/core:Basics.add", 2), ("elm/core:Basics.sub", 2), ("elm/core:Basics.mul", 2)
    , ("elm/core:Basics.fdiv", 2), ("elm/core:Basics.idiv", 2), ("elm/core:Basics.pow", 2)
    , ("elm/core:Basics.negate", 1)
    , ("elm/core:Basics.gt", 2), ("elm/core:Basics.ge", 2), ("elm/core:Basics.lt", 2), ("elm/core:Basics.le", 2)
    , ("elm/core:Basics.eq", 2), ("elm/core:Basics.neq", 2)
    , ("elm/core:Basics.and", 2), ("elm/core:Basics.or", 2), ("elm/core:Basics.not", 1)
    , ("elm/core:Basics.append", 2)
    , ("elm/core:String.fromInt", 1), ("elm/core:String.fromFloat", 1)
    , ("elm/core:Debug.log", 2), ("elm/core:Debug.toString", 1)
    , ("elm/core:Platform.worker", 1)
    , ("elm/core:Platform.Cmd.none", 0), ("elm/core:Platform.Sub.none", 0)
    ]


-- | variables of kernel functions keyed by their exact type even though the scheme does not say so
-- (the Printed roots of Ficcus.Mono.Marks: a printer is generated per type)
forcedExact :: String -> Int -> Bool
forcedExact cid ix =
  (cid, ix) `elem` [("elm/core:Debug.log", 0), ("elm/core:Debug.toString", 0)]
