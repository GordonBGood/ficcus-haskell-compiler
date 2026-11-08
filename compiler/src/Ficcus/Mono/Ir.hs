{-# OPTIONS_GHC -Wall #-}
module Ficcus.Mono.Ir
  ( CloneId(..)
  , MLit(..)
  , MExpr(..)
  , MNode(..)
  , MPat(..)
  , MPatNode(..)
  , DefKind(..)
  , MDef(..)
  , MProgram(..)
  , children
  , exprRefs
  )
  where


-- Ficcus, stage (iii): the monomorphic typed IR (docs/STAGE3-PLAN.md, section 1).
--
-- The output of the specializer and the input of `Lower`. Every node carries a representation class;
-- no node has a type variable. Calls name a clone (`MGlobal`), not a definition. Slice 0 only defines the
-- types and prints the clone table; slice 1 builds bodies.


import Ficcus.Mono.Class


newtype CloneId = CloneId Int
  deriving (Eq, Ord, Show)


data MLit
  = LInt Integer
  | LFloat Double
  | LChar Int                  -- code point
  | LString String
  | LUnit
  deriving (Eq, Show)


data MExpr = MExpr { mRep :: Class, mNode :: MNode }
  deriving (Show)


data MNode
  = MLit MLit
  | MLocal String                          -- parameter, let or pattern variable
  | MGlobal CloneId                        -- a top level clone: function or value
  | MKernel String Key                     -- a runtime (kernel) function at a key
  | MCtor String Int Key                   -- constructor name, tag, key of the type's parameters
  | MCall MExpr [MExpr]
  | MLam [(String, Class)] MExpr
  | MIf [(MExpr, MExpr)] MExpr
  | MLetVal String MExpr MExpr             -- let name = value in body (a local value; local functions are lifted clones)
  | MSeq MExpr MExpr                       -- evaluate the first for its effect, then the second
  | MCase MExpr [(MPat, MExpr)]
  | MAccess MExpr String
  | MUpdate MExpr [(String, MExpr)]
  | MRecord [(String, MExpr)]
  | MTuple [MExpr]
  | MList [MExpr]
  deriving (Show)


data MPat = MPat { mpRep :: Class, mpNode :: MPatNode }
  deriving (Show)


data MPatNode
  = PWild
  | PVar String
  | PLit MLit
  | PCtor String Int [MPat]                -- name, tag, arguments
  | PRecord [String]
  | PTuple [MPat]
  | PCons MPat MPat
  | PNil
  | PAlias MPat String
  deriving (Show)


data DefKind = Value | Function
  deriving (Eq, Show)


-- | one clone of a definition at a key
data MDef =
  MDef
    { mdClone :: CloneId
    , mdName :: String                     -- id of the definition
    , mdKey :: Key
    , mdKind :: DefKind
    , mdParams :: [(String, Class)]
    , mdResult :: Class
    , mdBody :: Maybe MExpr                -- Nothing while a clone is only listed (slice 0)
    , mdInit :: Maybe Int                  -- position in the module's initialisation order (top level)
    , mdNeeds :: [CloneId]                 -- clones of values that must be initialised first
    , mdLifted :: Maybe CloneId            -- a local function or lambda lifted out of this clone
    }
  deriving (Show)


data MProgram =
  MProgram
    { mpClones :: [MDef]                   -- in initialisation order, main last
    , mpMain :: Maybe CloneId
    }
  deriving (Show)


-- | the direct sub-expressions of a node, in evaluation order
children :: MExpr -> [MExpr]
children (MExpr _ node) =
  case node of
    MLit _ -> []
    MLocal _ -> []
    MGlobal _ -> []
    MKernel _ _ -> []
    MCtor _ _ _ -> []
    MCall f args -> f : args
    MLam _ b -> [b]
    MIf bs e -> concat [ [c, b] | (c, b) <- bs ] ++ [e]
    MLetVal _ v b -> [v, b]
    MSeq a b -> [a, b]
    MCase s bs -> s : map snd bs
    MAccess x _ -> [x]
    MUpdate x fs -> x : map snd fs
    MRecord fs -> map snd fs
    MTuple xs -> xs
    MList xs -> xs


-- | the clones an expression refers to, in order of first occurrence
exprRefs :: MExpr -> [CloneId]
exprRefs e =
  case mNode e of
    MGlobal c -> [c]
    _ -> concatMap exprRefs (children e)
