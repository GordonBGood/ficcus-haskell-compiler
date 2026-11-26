-- Ficcus (ATTACH, stage A3): the well known members.
--
-- A member of a custom type whose name is in the table below is used by the language itself: `add` by `+`,
-- `compare` by `<`, `compare`, `Dict` keys and `List.sort`, and so on (docs/attach/A3-NOTES.md, section 1).  This
-- module has the names, the type each of them must have (the shape), the bundles that Elm's `number`,
-- `comparable` and `appendable` stand for, and the table of the built-in types.  It has no logic of the solver.
module AST.WellKnown
  ( Shape(..)
  , shapeOf
  , builtinShapeOf
  , isWellKnown
  , fits
  , fitsVar
  , shapeAnnotation
  , expectedText
  , numberBundle
  , comparableBundle
  , appendableBundle
  , Builtin(..)
  , builtinOfApp
  , builtinHas
  , builtinChildren
  , operatorMember
  , isIntegral
  )
  where


import qualified Data.Map.Strict as Map

import qualified AST.Canonical as Can
import qualified AST.Prim.TypeName as T
import qualified AST.Prim.TypeVar as TV
import qualified Elm.ModuleName as ModuleName
import qualified String as S



-- SHAPES


-- | the type a well known member must have, with `s` the type it belongs to
data Shape
  = Binary      -- s -> s -> s                 add sub mul pow div idiv mod rem append
  | Compare     -- s -> s -> Order             compare
  | Equal       -- s -> s -> Bool              eq
  | Unary       -- s -> s                      neg abs
  | FromInt     -- Int -> s                    fromInt
  | FromFloat   -- Float -> s                  fromFloat (A3b: a Float literal at s)
  | Value       -- s                           zero (A5c: a member of the built-in number types, not a well known name)
  deriving (Eq)


-- | the shape of a member name; Nothing: not a well known name
shapeOf :: String -> Maybe Shape
shapeOf member =
  lookup member table
  where
    table =
      [ (m, Binary) | m <- ["add", "sub", "mul", "pow", "div", "idiv", "mod", "rem", "append"] ]
      ++ [ ("compare", Compare), ("eq", Equal), ("neg", Unary), ("abs", Unary), ("fromInt", FromInt), ("fromFloat", FromFloat) ]


-- | (A5c) the shape of a member that a built-in type can have: the well known ones, and `zero` (Int, Float; the sized
-- types define it in their `where` block).  `zero` is not a well known name: a custom type's `zero` can have any type,
-- and it is not part of the `number` bundle.
builtinShapeOf :: String -> Maybe Shape
builtinShapeOf member =
  case shapeOf member of
    Just shape -> Just shape
    Nothing | member == "zero" -> Just Value
    Nothing -> Nothing


isWellKnown :: String -> Bool
isWellKnown member =
  shapeOf member /= Nothing


-- | does the written type of a member of the type `home.tipe` have the shape?  (`s` is the type applied to
-- whatever arguments the declaration uses, the same in every place)
fits :: ModuleName.Canonical -> T.Name -> Shape -> Can.Type -> Bool
fits home tipe shape written =
  case (shape, spine written) of
    (Binary, [a, b, c]) -> self a && a == b && b == c
    (Compare, [a, b, c]) -> self a && a == b && c == order
    (Equal, [a, b, c]) -> self a && a == b && c == bool
    (Unary, [a, b]) -> self a && a == b
    (FromInt, [a, b]) -> a == int && self b
    (FromFloat, [a, b]) -> a == float && self b
    (Value, [a]) -> self a
    _ -> False
  where
    self t =
      case t of
        Can.TType h n args -> h == home && n == tipe && all isVar args
        _ -> False

    isVar t =
      case t of
        Can.TVar _ -> True
        _ -> False

    int = Can.TType ModuleName.basics T.int []
    float = Can.TType ModuleName.basics T.float []
    bool = Can.TType ModuleName.basics T.bool []
    order = Can.TType ModuleName.basics (T.nameFromString (S.fromChars "Order")) []


spine :: Can.Type -> [Can.Type]
spine t =
  case t of
    Can.TLambda a b -> a : spine b
    _ -> [t]


-- | (A5f, review M1) does the member type of a `where` line of a signature (`var has member : written`, aliases expanded by
-- the caller) have the shape, with the type variable `var` as `s`?  A built-in member has the well known shape, so with
-- this check a member of a built-in type never decides a variable other than its subject.
fitsVar :: String -> Shape -> Can.Type -> Bool
fitsVar var shape written =
  case (shape, spine written) of
    (Binary, [a, b, c]) -> self a && self b && self c
    (Compare, [a, b, c]) -> self a && self b && c == order
    (Equal, [a, b, c]) -> self a && self b && c == bool
    (Unary, [a, b]) -> self a && self b
    (FromInt, [a, b]) -> a == int && self b
    (FromFloat, [a, b]) -> a == float && self b
    (Value, [a]) -> self a
    _ -> False
  where
    self t =
      case t of
        Can.TVar v -> TV.varToChars v == var
        _ -> False

    int = Can.TType ModuleName.basics T.int []
    float = Can.TType ModuleName.basics T.float []
    bool = Can.TType ModuleName.basics T.bool []
    order = Can.TType ModuleName.basics (T.nameFromString (S.fromChars "Order")) []


-- | what the shape says in words, for the error message: the member `m` of the type `Money`
expectedText :: Shape -> String -> String
expectedText shape tipe =
  case shape of
    Binary -> tipe ++ " -> " ++ tipe ++ " -> " ++ tipe
    Compare -> tipe ++ " -> " ++ tipe ++ " -> Order"
    Equal -> tipe ++ " -> " ++ tipe ++ " -> Bool"
    Unary -> tipe ++ " -> " ++ tipe
    FromInt -> "Int -> " ++ tipe
    FromFloat -> "Float -> " ++ tipe
    Value -> tipe


-- | the shape as the scheme `(x, shape of x)` (a pair, so that one instantiation gives both the subject and the
-- member type): the solver unifies the first with the subject of an obligation and the second with its member type
shapeAnnotation :: Shape -> Can.Annotation
shapeAnnotation shape =
  Can.Forall (Map.singleton x ()) (Can.TPair (Can.TVar x) body)
  where
    x = TV.varFromString (S.fromChars "x")
    v = Can.TVar x
    int = Can.TType ModuleName.basics T.int []
    float = Can.TType ModuleName.basics T.float []
    bool = Can.TType ModuleName.basics T.bool []
    order = Can.TType ModuleName.basics (T.nameFromString (S.fromChars "Order")) []
    body =
      case shape of
        Binary -> Can.TLambda v (Can.TLambda v v)
        Compare -> Can.TLambda v (Can.TLambda v order)
        Equal -> Can.TLambda v (Can.TLambda v bool)
        Unary -> Can.TLambda v v
        FromInt -> Can.TLambda int v
        FromFloat -> Can.TLambda float v
        Value -> v



-- BUNDLES (Elm's own variables keep their exact meaning)


-- | `number`: everything but division
numberBundle :: [String]
numberBundle =
  ["add", "sub", "mul", "pow", "neg", "abs", "fromInt", "compare"]


comparableBundle :: [String]
comparableBundle =
  ["compare"]


appendableBundle :: [String]
appendableBundle =
  ["append"]



-- THE BUILT-IN TYPES


data Builtin
  = BInt
  | BFloat
  | BString
  | BChar
  | BList
  | BTuple
  | BOther      -- the other types that can be compared with `==` (Bool, Maybe, records, ...)
  | BFunction   -- no members


-- | the built-in type of a type constructor with this many arguments; Nothing: not one of the types that
-- have members of their own (Int, Float, String, Char, List)
builtinOfApp :: ModuleName.Canonical -> T.Name -> Int -> Maybe Builtin
builtinOfApp home name arity
  | home == ModuleName.basics && name == T.int && arity == 0 = Just BInt
  | home == ModuleName.basics && name == T.float && arity == 0 = Just BFloat
  | home == ModuleName.string && name == T.string && arity == 0 = Just BString
  | home == ModuleName.char && name == T.char && arity == 0 = Just BChar
  | home == ModuleName.list && name == T.list && arity == 1 = Just BList
  | otherwise = Nothing


-- | the members the built-in type has itself (those that need the members of its parts too are in
-- `builtinChildren`)
builtinHas :: Builtin -> String -> Bool
builtinHas kind member =
  case kind of
    BInt -> member `elem` (numberBundle ++ ["eq", "idiv", "mod", "rem", "zero"])
    BFloat -> member `elem` (numberBundle ++ ["eq", "div", "fromFloat", "zero"])
    BString -> member `elem` ["append", "compare", "eq"]
    BChar -> member `elem` ["compare", "eq"]
    BList -> member `elem` ["append", "compare", "eq"]
    BTuple -> member `elem` ["compare", "eq"]
    BOther -> member == "eq"
    BFunction -> False


-- | the members whose parts must have the member too (`List a` is comparable when `a` is)
builtinChildren :: Builtin -> String -> Bool
builtinChildren kind member =
  case kind of
    BList -> member == "compare"
    BTuple -> member == "compare"
    _ -> False


-- | the member that an operator or a function of `elm/core:Basics` stands for (by the id the specializer uses)
operatorMember :: String -> Maybe String
operatorMember cid =
  lookup cid
    [ ("elm/core:Basics.add", "add"), ("elm/core:Basics.sub", "sub"), ("elm/core:Basics.mul", "mul"), ("elm/core:Basics.pow", "pow")
    , ("elm/core:Basics.negate", "neg"), ("elm/core:Basics.abs", "abs")
    , ("elm/core:Basics.fdiv", "div"), ("elm/core:Basics.idiv", "idiv")
    , ("elm/core:Basics.modBy", "mod"), ("elm/core:Basics.remainderBy", "rem")
    , ("elm/core:Basics.append", "append")
    , ("elm/core:Basics.lt", "compare"), ("elm/core:Basics.gt", "compare"), ("elm/core:Basics.le", "compare")
    , ("elm/core:Basics.ge", "compare"), ("elm/core:Basics.compare", "compare")
    , ("elm/core:Basics.eq", "eq"), ("elm/core:Basics.neq", "eq")
    ]


-- | the members that are typed by their own type, not by Float and Int: the operators of Elm that are not
-- generic (`/` is Float only, `//`, `modBy`, `remainderBy` are Int only), see A3-NOTES section 3
isIntegral :: String -> Bool
isIntegral member =
  member `elem` ["idiv", "mod", "rem"]
