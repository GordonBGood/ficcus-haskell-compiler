{-# LANGUAGE MagicHash, TemplateHaskell #-}
module Type.Recorder
  ( Recorder
  , new
  , Key(..)
  , DefKey(..)
  , exprKey
  , valueKey
  , patKey
  , defKey
  , recordExpr
  , recordPat
  , recordDef
  , readNodes
  , readDefs
  , exprKind
  , patKind
  , isRecordedExpr
  )
  where


-- Ficus milestone 2: the type recorder.
--
-- In typed mode the constraint generator gives every expression and pattern
-- node (except the split Let/LetRec/LetDestruct nodes, whose type is the type
-- of their body) a type variable of its own, and every definition a variable
-- for its type scheme, and stores them here. After solving, Type.Readout turns
-- the variables into immutable types.
--
-- A node is identified by its source region and its kind. Nothing in
-- AST.Canonical carries an id, so two nodes of the same kind with the same
-- region would collide; the recorder treats that as an internal error.


import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import GHC.Word (Word64(..))

import qualified Crash

import qualified AST.Canonical as Can
import qualified AST.Prim.Name as N
import qualified Reporting.Annotation as A
import Type.Type (Variable)



-- RECORDER


data Recorder =
  Recorder
    { _nodes :: IORef (Map.Map Key Variable)
    , _defs :: IORef (Map.Map DefKey Variable)
    }


new :: IO Recorder
new =
  Recorder <$> newIORef Map.empty <*> newIORef Map.empty


readNodes :: Recorder -> IO (Map.Map Key Variable)
readNodes (Recorder ref _) =
  readIORef ref


readDefs :: Recorder -> IO (Map.Map DefKey Variable)
readDefs (Recorder _ ref) =
  readIORef ref



-- KEYS


-- start position, end position (packed row/column), "E:" or "P:" plus constructor name
data Key = Key !Word64 !Word64 String
  deriving (Eq, Ord, Show)


-- region of the defined name, and the name
data DefKey = DefKey !Word64 !Word64 N.Name
  deriving (Eq, Ord)


exprKey :: A.Region -> Can.Expr_ -> Key
exprKey region expr =
  mkKey region ("E:" ++ exprKind expr)


-- the key of the node that carries the type of an expression used as a value: a `let` is not recorded (see
-- isRecordedExpr), its type is the type of its body
valueKey :: A.Region -> Can.Expr_ -> Key
valueKey region expr =
  case expr of
    Can.Let _ (A.At r body)           -> valueKey r body
    Can.LetRec _ (A.At r body)        -> valueKey r body
    Can.LetDestruct _ _ (A.At r body) -> valueKey r body
    _                                 -> exprKey region expr


patKey :: A.Region -> Can.Pattern_ -> Key
patKey region pattern =
  mkKey region ("P:" ++ patKind pattern)


defKey :: A.Region -> N.Name -> DefKey
defKey (A.Region s e) name =
  DefKey (W64# s) (W64# e) name


mkKey :: A.Region -> String -> Key
mkKey (A.Region s e) kind =
  Key (W64# s) (W64# e) kind



-- RECORD


recordExpr :: Recorder -> A.Region -> Can.Expr_ -> Variable -> IO ()
recordExpr (Recorder ref _) region expr var =
  insertNode ref (exprKey region expr) var


recordPat :: Recorder -> A.Region -> Can.Pattern_ -> Variable -> IO ()
recordPat (Recorder ref _) region pattern var =
  insertNode ref (patKey region pattern) var


insertNode :: IORef (Map.Map Key Variable) -> Key -> Variable -> IO ()
insertNode ref key var =
  do  nodes <- readIORef ref
      if Map.member key nodes
        then $(Crash.crashIO 'insertNode) ("type recorder: two nodes have the same key " ++ show key ++ "; node ids are needed in Can.Expr")
        else writeIORef ref (Map.insert key var nodes)


recordDef :: Recorder -> A.Region -> N.Name -> Variable -> IO ()
recordDef (Recorder _ ref) region name var =
  do  defs <- readIORef ref
      let key = defKey region name
      if Map.member key defs
        then $(Crash.crashIO 'recordDef) "type recorder: a definition was recorded twice"
        else writeIORef ref (Map.insert key var defs)



-- KINDS


-- Let, LetRec and LetDestruct are not recorded: when one source `let` is split
-- into several, the nested nodes share one region.
isRecordedExpr :: Can.Expr_ -> Bool
isRecordedExpr expr =
  case expr of
    Can.Let _ _          -> False
    Can.LetRec _ _       -> False
    Can.LetDestruct _ _ _ -> False
    _                    -> True


exprKind :: Can.Expr_ -> String
exprKind expr =
  case expr of
    Can.VarLocal _          -> "VarLocal"
    Can.VarTopLevel _ _     -> "VarTopLevel"
    Can.VarKernel _ _       -> "VarKernel"
    Can.VarForeign _ _ _    -> "VarForeign"
    Can.VarCtor _ _ _ _ _   -> "VarCtor"
    Can.VarDebug _ _ _      -> "VarDebug"
    Can.VarOperator _ _ _ _ -> "VarOperator"
    Can.Chr _               -> "Chr"
    Can.Str _               -> "Str"
    Can.Int _               -> "Int"
    Can.Float _             -> "Float"
    Can.List _              -> "List"
    Can.Negate _            -> "Negate"
    Can.Binop _ _ _ _ _ _   -> "Binop"
    Can.Lambda _ _          -> "Lambda"
    Can.Call _ _            -> "Call"
    Can.If _ _              -> "If"
    Can.Let _ _             -> "Let"
    Can.LetRec _ _          -> "LetRec"
    Can.LetDestruct _ _ _   -> "LetDestruct"
    Can.Case _ _            -> "Case"
    Can.Accessor _          -> "Accessor"
    Can.Access _ _          -> "Access"
    Can.Update _ _ _        -> "Update"
    Can.Record _            -> "Record"
    Can.Unit                -> "Unit"
    Can.Pair _ _            -> "Pair"
    Can.Triple _ _ _        -> "Triple"
    Can.Shader _ _          -> "Shader"


patKind :: Can.Pattern_ -> String
patKind pattern =
  case pattern of
    Can.PAnything     -> "PAnything"
    Can.PVar _        -> "PVar"
    Can.PRecord _     -> "PRecord"
    Can.PAlias _ _    -> "PAlias"
    Can.PUnit         -> "PUnit"
    Can.PPair _ _     -> "PPair"
    Can.PTriple _ _ _ -> "PTriple"
    Can.PList _       -> "PList"
    Can.PCons _ _     -> "PCons"
    Can.PBool _ _     -> "PBool"
    Can.PChr _        -> "PChr"
    Can.PStr _        -> "PStr"
    Can.PInt _        -> "PInt"
    Can.PCtor {}      -> "PCtor"
