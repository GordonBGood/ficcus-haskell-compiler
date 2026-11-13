{-# OPTIONS_GHC -Wall #-}
module Ficcus.Mono.Ir
  ( CloneId(..)
  , MLit(..)
  , MExpr(..)
  , MNode(..)
  , MPat(..)
  , MPatNode(..)
  , DefKind(..)
  , Own(..)
  , paramOwns
  , MDef(..)
  , MProgram(..)
  , UnionShape(..)
  , children
  , exprRefs
  )
  where


-- Ficcus, stage (iii): the monomorphic typed IR (docs/STAGE3-PLAN.md, section 1).
--
-- The output of the specializer and the input of `Lower`. Every node carries a representation class;
-- no node has a type variable. Calls name a clone (`MGlobal`), not a definition. Slice 0 only defines the
-- types and prints the clone table; slice 1 builds bodies.


import qualified Data.Map.Strict as Map

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
  | MAccess MExpr String Int               -- record, field name, position of the field (fields are in alphabetical order)
  | MUpdate MExpr [(String, MExpr)]
  | MRecord [(String, MExpr)]
  | MTuple [MExpr]
  | MList [MExpr]
  -- added by the Rc pass (Ficcus.Mono.Rc, STAGE4-PLAN section 3); the specializer never makes them
  | MDup [(String, Class)] MExpr           -- add a count to each variable (a struct: to each reference component), then the expression
  | MDrop [(String, Class)] MExpr          -- remove a count from each variable, then the expression
  | MUnpack String Class [(String, Class, [Int])] MExpr
      -- a struct variable that dies here is taken apart: each listed (pattern) variable takes over the counts on the given reference
      -- leaves (indices into the reference leaves of the struct, in order); the counts on all other leaves are dropped (S3, per component)
  | MSpec String [Class] [(String, Class, Int)] (Maybe String) MExpr
      -- S4 drop specialization, always the whole body of a case branch: the scrutinee variable (owned, dies here) is a heap object whose fields
      -- have these classes; each listed pattern variable (with the index of its field) takes over the count of that field. When the object is
      -- unique the other reference fields are dropped and the cell becomes the reuse token of the given name (it is freed at once when there
      -- is no token); when it is shared every listed variable gets a count of its own and the object loses one
  | MReuse String MExpr                    -- S4: the expression is a constructor application (or a cons): it is built in the cell of the token
                                           -- (a fresh cell when the token is empty); consumes the token
  | MFreeTok String MExpr                  -- S4: the token is not used on this path: free its cell, then the expression
  | MOwn MExpr                             -- the expression is a borrowed value (a view into something that stays alive): add a count, the result is owned
  deriving (Show)


data MPat = MPat { mpRep :: Class, mpNode :: MPatNode }
  deriving (Show)


data MPatNode
  = PWild
  | PVar String
  | PLit MLit
  | PCtor String Int [MPat]                -- name, tag, arguments
  | PRecord [(Int, String, Class)]         -- position, name and class of each field bound
  | PTuple [MPat]
  | PCons MPat MPat
  | PNil
  | PAlias MPat String
  deriving (Show)


data DefKind = Value | Function
  deriving (Eq, Show)


-- | how a function treats a parameter of a reference class (STAGE4-PLAN section 4): it consumes a count (owned), or only looks at the
-- value, which the caller keeps alive for the whole call (borrowed)
data Own = Owned | Borrowed
  deriving (Eq, Show)


-- | the ownership of every parameter of a clone (all owned when the inference has not run)
paramOwns :: MDef -> [Own]
paramOwns d = take (length (mdParams d)) (mdOwn d ++ repeat Owned)


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
    , mdLifted :: Maybe CloneId            -- the clone a local function or lambda was lifted out of (its owner)
    , mdVars :: [Int]                      -- the scheme variable index of each part of the key (own variables only:
                                           -- the variables of an enclosing definition belong to the owner's key)
    , mdOwn :: [Own]                       -- ownership of each parameter (S3, Ficcus.Mono.Borrow); empty: all owned (the specializer's output)
    , mdTwin :: Maybe CloneId              -- S7 part 3 (Ficcus.Mono.Twin): the copy of this lifted clone that OWNS its captured variables; the
                                           -- closure object enters it when the call consumes a closure that nobody else holds
    , mdCapsOwned :: Bool                  -- this clone is such a copy: its captured variables are owned (they are borrowed in every other clone)
    }
  deriving (Show)


-- | a custom type as the generated `==` and `compare` need it: whether every constructor is nullary, and the
-- constructors (name, tag, field types). A type parameter inside a field type is `TyCon "#<i>" []` (the i-th
-- parameter); the generator substitutes the arguments of the exact type.
data UnionShape =
  UnionShape
    { usEnum :: Bool
    , usCtors :: [(String, Int, [MType])]
    }
  deriving (Show)


data MProgram =
  MProgram
    { mpClones :: [MDef]                   -- in initialisation order, main last
    , mpMain :: Maybe CloneId
    , mpUnions :: Map.Map String UnionShape  -- every custom type of every module, by `Module.Type`
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
    MAccess x _ _ -> [x]
    MUpdate x fs -> x : map snd fs
    MRecord fs -> map snd fs
    MTuple xs -> xs
    MList xs -> xs
    MDup _ e -> [e]
    MDrop _ e -> [e]
    MOwn e -> [e]
    MUnpack _ _ _ e -> [e]
    MSpec _ _ _ _ e -> [e]
    MReuse _ e -> [e]
    MFreeTok _ e -> [e]


-- | the clones an expression refers to, in order of first occurrence
exprRefs :: MExpr -> [CloneId]
exprRefs e =
  case mNode e of
    MGlobal c -> [c]
    _ -> concatMap exprRefs (children e)
