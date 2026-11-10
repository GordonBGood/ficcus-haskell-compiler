{-# OPTIONS_GHC -Wall #-}
module Ficcus.Mono.Kernel
  ( kernelArity
  , forcedExact
  , directKernelIds
  , kernelSig
  , kernelResultBorrowed
  )
  where


import Ficcus.Mono.Class (AppClass(..), Key(..), KeyPart(..))


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
    [ ("elm/core:Basics.add", 2), ("elm/core:Basics.sub", 2), ("elm/core:Basics.mul", 2), ("elm/core:Basics.mulRound53", 2)
    , ("elm/core:Basics.fdiv", 2), ("elm/core:Basics.idiv", 2), ("elm/core:Basics.pow", 2)
    , ("elm/core:Basics.negate", 1), ("elm/core:Basics.modBy", 2), ("elm/core:Basics.remainderBy", 2)
    , ("elm/core:Basics.gt", 2), ("elm/core:Basics.ge", 2), ("elm/core:Basics.lt", 2), ("elm/core:Basics.le", 2)
    , ("elm/core:Basics.eq", 2), ("elm/core:Basics.neq", 2)
    , ("elm/core:Basics.and", 2), ("elm/core:Basics.or", 2), ("elm/core:Basics.not", 1)
    , ("elm/core:Basics.compare", 2)
    , ("elm/core:Basics.toFloat", 1), ("elm/core:Basics.round", 1), ("elm/core:Basics.floor", 1), ("elm/core:Basics.ceiling", 1)
    , ("elm/core:Basics.truncate", 1), ("elm/core:Basics.sqrt", 1), ("elm/core:Basics.log", 1), ("elm/core:Basics.logBase", 2), ("elm/core:Basics.xor", 2)
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
    , ("elm/parser:Parser.Advanced.isSubString", 5), ("elm/parser:Parser.Advanced.findSubString", 5), ("elm/parser:Parser.Advanced.isSubChar", 3)
    , ("elm/parser:Parser.Advanced.isAsciiCode", 3), ("elm/parser:Parser.Advanced.chompBase10", 2)
    , ("elm/parser:Parser.Advanced.consumeBase", 3), ("elm/parser:Parser.Advanced.consumeBase16", 2)
    , ("elm/core:Debug.todo", 1)
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


-- | the table ids that `Elm.Kernel.<module>.<name>` written directly in a package body may stand for (the wrappers of elm/core
-- are named `elm/core:<module>.<name>`; the kernels of other packages are called from the module that declares the wrapper)
directKernelIds :: String -> String -> [String]
directKernelIds m n =
  case m of
    "Parser" -> [ "elm/parser:Parser.Advanced." ++ n ]
    _ -> [ "elm/core:" ++ m ++ "." ++ n ]



-- | the ownership signature of a kernel (STAGE4-PLAN section 8): one letter per argument, `s` an argument that is never a
-- reference (no count), `b` a reference argument the kernel only borrows (the caller keeps its count and drops it after the
-- call), `o` a reference argument the kernel consumes (stores it, returns it or drops it, on every path). Where an argument can be
-- of a scalar class at one key and of a reference class at another (the `a` of `foldl`) the letter says what it is when it is a
-- reference. The result is always owned, except for the kernels in `kernelResultBorrowed`. The defaults are: every
-- reference argument borrowed, so a kernel that is not listed is `bbb..`.
-- The table is checked against the arities of `kernelArity` when the Rc pass starts (a missing entry is an error of the compiler).
kernelSig :: String -> Key -> Maybe String
kernelSig cid key =
  case (cid, key) of
    ("elm/core:Basics.append", Key [ByApp AStr]) -> Just "bb"
    ("elm/core:Basics.append", _) -> Just "bo"           -- xs is copied (its elements are dup'd), ys becomes the tail of the result
    _ -> lookup cid table
  where
    table =
      [ ("elm/core:List.cons", "oo")
      -- Elm.JsArray: the array of unsafeSet and push is consumed (updated in place when unique, S6; copied until then); the
      -- element of singleton, unsafeSet and push is stored; unsafeGet returns a borrowed element (the pass adds the count)
      , ("elm/core:Elm.JsArray.empty", ""), ("elm/core:Elm.JsArray.singleton", "o"), ("elm/core:Elm.JsArray.length", "b")
      , ("elm/core:Elm.JsArray.initialize", "ssb"), ("elm/core:Elm.JsArray.initializeFromList", "sb")
      , ("elm/core:Elm.JsArray.unsafeGet", "sb"), ("elm/core:Elm.JsArray.unsafeSet", "soo"), ("elm/core:Elm.JsArray.push", "oo")
      , ("elm/core:Elm.JsArray.foldl", "bob"), ("elm/core:Elm.JsArray.foldr", "bob"), ("elm/core:Elm.JsArray.map", "bb")
      , ("elm/core:Elm.JsArray.indexedMap", "bsb"), ("elm/core:Elm.JsArray.slice", "ssb"), ("elm/core:Elm.JsArray.appendN", "sbb")
      -- String and Char: every string is borrowed, the results are new strings (or counted copies)
      , ("elm/core:String.length", "b"), ("elm/core:String.slice", "ssb"), ("elm/core:String.cons", "sb"), ("elm/core:String.join", "bb")
      , ("elm/core:String.words", "b"), ("elm/core:String.toUpper", "b"), ("elm/core:String.toLower", "b"), ("elm/core:String.map", "bb")
      , ("elm/core:String.foldl", "bob"), ("elm/core:String.foldr", "bob"), ("elm/core:String.fromList", "b")
      , ("elm/core:String.append", "bb"), ("elm/core:String.contains", "bb"), ("elm/core:String.startsWith", "bb")
      , ("elm/core:String.endsWith", "bb"), ("elm/core:String.indexes", "bb"), ("elm/core:String.indices", "bb")
      , ("elm/core:String.split", "bb"), ("elm/core:String.lines", "b"), ("elm/core:String.reverse", "b"), ("elm/core:String.trim", "b")
      , ("elm/core:String.trimLeft", "b"), ("elm/core:String.trimRight", "b"), ("elm/core:String.uncons", "b")
      , ("elm/core:String.filter", "bb"), ("elm/core:String.any", "bb"), ("elm/core:String.all", "bb"), ("elm/core:String.toInt", "b")
      , ("elm/core:String.toFloat", "b"), ("elm/core:String.fromInt", "s"), ("elm/core:String.fromFloat", "s")
      , ("elm/core:Char.toCode", "s"), ("elm/core:Char.toUpper", "s"), ("elm/core:Char.toLower", "s"), ("elm/core:Char.fromCode", "s")
      , ("elm/core:Char.toLocaleUpper", "s"), ("elm/core:Char.toLocaleLower", "s")
      -- elm/parser: the source string is borrowed; the string cache of the kernels keeps its own count
      , ("elm/parser:Parser.Advanced.isSubString", "bsssb"), ("elm/parser:Parser.Advanced.findSubString", "bsssb")
      , ("elm/parser:Parser.Advanced.isSubChar", "bsb"), ("elm/parser:Parser.Advanced.isAsciiCode", "ssb")
      , ("elm/parser:Parser.Advanced.chompBase10", "sb"), ("elm/parser:Parser.Advanced.consumeBase", "ssb")
      , ("elm/parser:Parser.Advanced.consumeBase16", "sb")
      -- Debug: the tag is borrowed, the value is returned by log (so owned); toString only reads its argument
      , ("elm/core:Debug.todo", "b"), ("elm/core:Debug.log", "bo"), ("elm/core:Debug.toString", "b")
      , ("elm/core:Platform.worker", "b"), ("elm/core:Platform.Cmd.none", ""), ("elm/core:Platform.Sub.none", "")
      -- Basics: comparisons and equality read two values of the key's type
      , ("elm/core:Basics.eq", "bb"), ("elm/core:Basics.neq", "bb"), ("elm/core:Basics.gt", "bb"), ("elm/core:Basics.ge", "bb")
      , ("elm/core:Basics.lt", "bb"), ("elm/core:Basics.le", "bb"), ("elm/core:Basics.compare", "bb")
      ]
      ++ [ (n, replicate k 's') | (n, k) <- scalarKernels ]


-- the kernels whose arguments are never references
scalarKernels :: [(String, Int)]
scalarKernels =
  [ ("elm/core:Basics." ++ n, k)
  | (n, k) <- [ ("add", 2), ("sub", 2), ("mul", 2), ("mulRound53", 2), ("fdiv", 2), ("idiv", 2), ("pow", 2), ("negate", 1)
              , ("modBy", 2), ("remainderBy", 2), ("and", 2), ("or", 2), ("not", 1), ("toFloat", 1), ("round", 1), ("floor", 1)
              , ("ceiling", 1), ("truncate", 1), ("sqrt", 1), ("log", 1), ("logBase", 2), ("xor", 2), ("sin", 1), ("cos", 1)
              , ("tan", 1), ("asin", 1), ("acos", 1), ("atan", 1), ("atan2", 2), ("isNaN", 1), ("isInfinite", 1), ("e", 0), ("pi", 0) ] ]
  ++ [ ("elm/core:Bitwise." ++ n, k) | (n, k) <- bitwise ]
  ++ [ ("elm/core:Bitwise64." ++ n, k) | (n, k) <- bitwise ]
  where
    bitwise = [ ("and", 2), ("or", 2), ("xor", 2), ("complement", 1), ("shiftLeftBy", 2), ("shiftRightBy", 2), ("shiftRightZfBy", 2) ]


-- | kernels that return a reference they do not own (a counted element of an array): the caller adds the count
kernelResultBorrowed :: String -> Bool
kernelResultBorrowed cid = cid == "elm/core:Elm.JsArray.unsafeGet"
