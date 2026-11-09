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
    , ("elm/core:Basics.negate", 1), ("elm/core:Basics.modBy", 2), ("elm/core:Basics.remainderBy", 2)
    , ("elm/core:Basics.gt", 2), ("elm/core:Basics.ge", 2), ("elm/core:Basics.lt", 2), ("elm/core:Basics.le", 2)
    , ("elm/core:Basics.eq", 2), ("elm/core:Basics.neq", 2)
    , ("elm/core:Basics.and", 2), ("elm/core:Basics.or", 2), ("elm/core:Basics.not", 1)
    , ("elm/core:Basics.compare", 2)
    , ("elm/core:Basics.toFloat", 1), ("elm/core:Basics.round", 1), ("elm/core:Basics.floor", 1), ("elm/core:Basics.ceiling", 1)
    , ("elm/core:Basics.truncate", 1), ("elm/core:Basics.sqrt", 1), ("elm/core:Basics.log", 1), ("elm/core:Basics.xor", 2)
    , ("elm/core:Basics.sin", 1), ("elm/core:Basics.cos", 1), ("elm/core:Basics.tan", 1), ("elm/core:Basics.asin", 1)
    , ("elm/core:Basics.acos", 1), ("elm/core:Basics.atan", 1), ("elm/core:Basics.atan2", 2)
    , ("elm/core:Basics.isNaN", 1), ("elm/core:Basics.isInfinite", 1), ("elm/core:Basics.e", 0), ("elm/core:Basics.pi", 0)
    , ("elm/core:Bitwise.and", 2), ("elm/core:Bitwise.or", 2), ("elm/core:Bitwise.xor", 2), ("elm/core:Bitwise.complement", 1)
    , ("elm/core:Bitwise.shiftLeftBy", 2), ("elm/core:Bitwise.shiftRightBy", 2), ("elm/core:Bitwise.shiftRightZfBy", 2)
    , ("elm/core:Bitwise64.and", 2), ("elm/core:Bitwise64.or", 2), ("elm/core:Bitwise64.xor", 2), ("elm/core:Bitwise64.complement", 1)
    , ("elm/core:Bitwise64.shiftLeftBy", 2), ("elm/core:Bitwise64.shiftRightBy", 2), ("elm/core:Bitwise64.shiftRightZfBy", 2)
    , ("elm/core:Basics.append", 2), ("elm/core:List.cons", 2)
    , ("elm/core:Elm.JsArray.empty", 0), ("elm/core:Elm.JsArray.singleton", 1), ("elm/core:Elm.JsArray.length", 1)
    , ("elm/core:Elm.JsArray.initialize", 3), ("elm/core:Elm.JsArray.initializeFromList", 2)
    , ("elm/core:Elm.JsArray.unsafeGet", 2), ("elm/core:Elm.JsArray.unsafeSet", 3), ("elm/core:Elm.JsArray.push", 2)
    , ("elm/core:Elm.JsArray.foldl", 3), ("elm/core:Elm.JsArray.foldr", 3), ("elm/core:Elm.JsArray.map", 2)
    , ("elm/core:Elm.JsArray.indexedMap", 3), ("elm/core:Elm.JsArray.slice", 3), ("elm/core:Elm.JsArray.appendN", 3)
    , ("elm/core:String.length", 1), ("elm/core:String.slice", 3), ("elm/core:String.cons", 2), ("elm/core:String.join", 2)
    , ("elm/core:String.words", 1), ("elm/core:String.toUpper", 1), ("elm/core:String.toLower", 1), ("elm/core:String.map", 2)
    , ("elm/core:String.foldl", 3), ("elm/core:String.foldr", 3), ("elm/core:Char.toCode", 1)
    , ("elm/core:Char.toUpper", 1), ("elm/core:Char.toLower", 1), ("elm/core:String.fromList", 1)
    , ("elm/core:String.append", 2), ("elm/core:String.contains", 2), ("elm/core:String.startsWith", 2), ("elm/core:String.endsWith", 2)
    , ("elm/core:String.indexes", 2), ("elm/core:String.indices", 2), ("elm/core:String.split", 2), ("elm/core:String.lines", 1), ("elm/core:String.reverse", 1)
    , ("elm/core:String.trim", 1), ("elm/core:String.trimLeft", 1), ("elm/core:String.trimRight", 1), ("elm/core:String.uncons", 1)
    , ("elm/core:String.filter", 2), ("elm/core:String.any", 2), ("elm/core:String.all", 2), ("elm/core:String.toInt", 1), ("elm/core:String.toFloat", 1)
    , ("elm/core:Char.fromCode", 1), ("elm/core:Char.toLocaleUpper", 1), ("elm/core:Char.toLocaleLower", 1)
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
