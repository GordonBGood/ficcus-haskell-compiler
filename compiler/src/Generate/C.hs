{-# OPTIONS_GHC -Wall #-}
module Generate.C
  ( dump
  )
  where


-- Ficus milestone 1: the C back end is only a dump of the optimized graph.
--
-- It walks the nodes reachable from each `main`, in the same way as
-- Generate.JavaScript.addGlobal, but never expands Kernel nodes and stops at
-- Platform.worker (the temporary entry point of the planned C back end), and
-- lists every kernel name it meets. Every line is a C99 line comment, so the
-- output file is a valid (empty) C translation unit.


import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Set as Set

import qualified String as S

import qualified AST.Optimized as Opt
import qualified AST.Prim.Module as Module
import qualified AST.Prim.Name as N
import qualified Data.Index as Index
import qualified Elm.Float as EF
import qualified Elm.ModuleName as ModuleName
import qualified Elm.Package as Pkg
import qualified Elm.String as ES
import qualified Optimize.DecisionTree as DT



-- DUMP


dump :: Opt.GlobalGraph -> Map.Map ModuleName.Canonical Opt.Main -> B.Builder
dump (Opt.GlobalGraph graph _) mains =
  let
    roots = map (\home -> Opt.Global home N.main) (Map.keys mains)
    walk = List.foldl' (visit graph) (Walk Set.empty [] [] [] []) roots
    nodes = List.sortOn (fst . fst) (reverse (_nodes walk))
    kernelNames = Set.fromList (concatMap (kernelVars . snd) nodes)
    kernelNodes = Set.fromList (map kernelModule (_kernelNodes walk))
  in
  toBuilder (
    [ "Ficus milestone 1: dump of the optimized graph reachable from main"
    , "roots: " ++ unwords (map showGlobal roots)
    , "nodes: " ++ show (length nodes)
    , ""
    , "stopped at Platform.worker (not expanded):"
    ]
    ++ indent (map showGlobal (reverse (_stops walk)))
    ++ [ "", "kernel modules reached (not expanded):" ]
    ++ indent (Set.toList kernelNodes)
    ++ [ "", "kernel names used (Elm.Kernel.Module.name):" ]
    ++ indent (Set.toList kernelNames)
    ++ [ "", "missing from the graph:" ]
    ++ indent (map showGlobal (reverse (_missing walk)))
    ++ concatMap dumpNode nodes
  )
  <> B.string7 "\ntypedef int ficus_dump_is_not_a_program; /* keeps the translation unit non-empty */\n"


toBuilder :: [String] -> B.Builder
toBuilder ls =
  mconcat (map (\l -> B.string7 "// " <> B.stringUtf8 l <> B.char7 '\n') ls)


indent :: [String] -> [String]
indent ls =
  case ls of
    [] -> [ "  (none)" ]
    _  -> map ("  " ++) ls



-- WALK


data Walk =
  Walk
    { _seen :: Set.Set Opt.Global
    , _nodes :: [((String, String), Opt.Node)]
    , _kernelNodes :: [Opt.Global]
    , _stops :: [Opt.Global]
    , _missing :: [Opt.Global]
    }


visit :: Map.Map Opt.Global Opt.Node -> Walk -> Opt.Global -> Walk
visit graph walk global =
  if Set.member global (_seen walk) then
    walk
  else
    let seen = walk { _seen = Set.insert global (_seen walk) } in
    case Map.lookup global graph of
      Nothing ->
        seen { _missing = global : _missing seen }

      Just node ->
        case node of
          Opt.Kernel _ _ ->
            seen { _kernelNodes = global : _kernelNodes seen }

          _ | isWorker global ->
            seen { _stops = global : _stops seen
                 , _nodes = (key global, node) : _nodes seen
                 }

          _ ->
            List.foldl' (visit graph)
              (seen { _nodes = (key global, node) : _nodes seen })
              (Set.toList (nodeDeps node))


isWorker :: Opt.Global -> Bool
isWorker (Opt.Global home name) =
  home == ModuleName.platform && N.toChars name == "worker"


key :: Opt.Global -> (String, String)
key (Opt.Global (ModuleName.Canonical pkg home) name) =
  (Pkg.toChars pkg ++ " " ++ Module.toChars home, N.toChars name)


nodeDeps :: Opt.Node -> Set.Set Opt.Global
nodeDeps node =
  case node of
    Opt.Define _ deps          -> deps
    Opt.DefineTailFunc _ _ deps -> deps
    Opt.Ctor _ _               -> Set.empty
    Opt.Enum _                 -> Set.empty
    Opt.Box                    -> Set.empty
    Opt.Link g                 -> Set.singleton g
    Opt.Cycle _ _ _ deps       -> deps
    Opt.Manager _              -> Set.empty
    Opt.Kernel _ deps          -> deps
    Opt.PortIncoming _ deps    -> deps
    Opt.PortOutgoing _ deps    -> deps



-- KERNEL NAMES


kernelVars :: Opt.Node -> [String]
kernelVars node =
  case node of
    Opt.Define e _           -> exprKernel e
    Opt.DefineTailFunc _ e _ -> exprKernel e
    Opt.Cycle _ vs fs _      -> concatMap (exprKernel . snd) vs ++ concatMap defKernel fs
    Opt.PortIncoming e _     -> exprKernel e
    Opt.PortOutgoing e _     -> exprKernel e
    _                        -> []


defKernel :: Opt.Def -> [String]
defKernel def =
  case def of
    Opt.Def _ e       -> exprKernel e
    Opt.TailDef _ _ e -> exprKernel e


exprKernel :: Opt.Expr -> [String]
exprKernel expr =
  case expr of
    Opt.VarKernel h n   -> [ "Elm.Kernel." ++ S.toChars (Module.kernelToString h) ++ "." ++ N.toChars n ]
    Opt.List es         -> concatMap exprKernel es
    Opt.Function _ b    -> exprKernel b
    Opt.Call f xs       -> concatMap exprKernel (f : xs)
    Opt.TailCall _ xs   -> concatMap (exprKernel . snd) xs
    Opt.If bs f         -> concatMap (\(c, b) -> exprKernel c ++ exprKernel b) bs ++ exprKernel f
    Opt.Let d b         -> defKernel d ++ exprKernel b
    Opt.Destruct _ b    -> exprKernel b
    Opt.Case _ _ d js   -> deciderKernel d ++ concatMap (exprKernel . snd) js
    Opt.Access e _      -> exprKernel e
    Opt.Update e fs     -> exprKernel e ++ concatMap exprKernel (Map.elems fs)
    Opt.Record fs       -> concatMap exprKernel (Map.elems fs)
    Opt.Pair a b        -> exprKernel a ++ exprKernel b
    Opt.Triple a b c    -> concatMap exprKernel [a, b, c]
    _                   -> []


deciderKernel :: Opt.Decider Opt.Choice -> [String]
deciderKernel decider =
  case decider of
    Opt.Leaf choice          -> choiceKernel choice
    Opt.Chain _ s f          -> deciderKernel s ++ deciderKernel f
    Opt.FanOut _ tests fall  -> concatMap (deciderKernel . snd) tests ++ deciderKernel fall


choiceKernel :: Opt.Choice -> [String]
choiceKernel choice =
  case choice of
    Opt.Inline e -> exprKernel e
    Opt.Jump _   -> []



-- PRINT NODES


dumpNode :: ((String, String), Opt.Node) -> [String]
dumpNode ((home, name), node) =
  "" : (home ++ " " ++ name ++ " = " ++ nodeHead node) : indent2 (nodeBody node)
    where
      indent2 = map ("  " ++)


nodeHead :: Opt.Node -> String
nodeHead node =
  case node of
    Opt.Define _ _            -> "Define"
    Opt.DefineTailFunc xs _ _ -> "DefineTailFunc " ++ unwords (map N.toChars xs)
    Opt.Ctor i n              -> "Ctor index=" ++ show (Index.toMachine i) ++ " arity=" ++ show n
    Opt.Enum i                -> "Enum index=" ++ show (Index.toMachine i)
    Opt.Box                   -> "Box"
    Opt.Link g                -> "Link " ++ showGlobal g
    Opt.Cycle ns _ _ _        -> "Cycle " ++ unwords (map N.toChars ns)
    Opt.Manager _             -> "Manager"
    Opt.Kernel cs _           -> "Kernel (" ++ show (length cs) ++ " chunks)"
    Opt.PortIncoming _ _      -> "PortIncoming"
    Opt.PortOutgoing _ _      -> "PortOutgoing"


nodeBody :: Opt.Node -> [String]
nodeBody node =
  case node of
    Opt.Define e _            -> ppExpr e
    Opt.DefineTailFunc _ e _  -> ppExpr e
    Opt.Cycle _ vs fs _       ->
      concatMap (\(n, e) -> ("value " ++ N.toChars n ++ " =") : map ("  " ++) (ppExpr e)) vs
      ++ concatMap ppDef fs
    Opt.PortIncoming e _      -> ppExpr e
    Opt.PortOutgoing e _      -> ppExpr e
    _                         -> []


showGlobal :: Opt.Global -> String
showGlobal (Opt.Global (ModuleName.Canonical pkg home) name) =
  Pkg.toChars pkg ++ ":" ++ Module.toChars home ++ "." ++ N.toChars name


kernelModule :: Opt.Global -> String
kernelModule (Opt.Global (ModuleName.Canonical _ home) _) =
  "Elm.Kernel." ++ Module.toChars home


showHome :: ModuleName.Canonical -> String
showHome (ModuleName.Canonical pkg home) =
  Pkg.toChars pkg ++ ":" ++ Module.toChars home


ppDef :: Opt.Def -> [String]
ppDef def =
  case def of
    Opt.Def n e ->
      ("def " ++ N.toChars n ++ " =") : map ("  " ++) (ppExpr e)

    Opt.TailDef n xs e ->
      ("tailDef " ++ N.toChars n ++ " " ++ unwords (map N.toChars xs) ++ " =") : map ("  " ++) (ppExpr e)


ppExpr :: Opt.Expr -> [String]
ppExpr expr =
  case expr of
    Opt.Bool b            -> [ "Bool " ++ show b ]
    Opt.Chr c             -> [ "Chr " ++ show c ]
    Opt.Str s             -> [ "Str " ++ show (ES.toChars s) ]
    Opt.Int i             -> [ "Int " ++ show i ]
    Opt.Float f           -> [ "Float " ++ LBS.unpack (B.toLazyByteString (EF.toBuilder f)) ]
    Opt.VarLocal n        -> [ "local " ++ N.toChars n ]
    Opt.VarGlobal g       -> [ "global " ++ showGlobal g ]
    Opt.VarEnum g i       -> [ "enum " ++ showGlobal g ++ " #" ++ show (Index.toMachine i) ]
    Opt.VarBox g          -> [ "box " ++ showGlobal g ]
    Opt.VarCycle h n      -> [ "cycle " ++ showHome h ++ "." ++ N.toChars n ]
    Opt.VarDebug n h _ _  -> [ "debug " ++ N.toChars n ++ " (from " ++ showHome h ++ ")" ]
    Opt.VarKernel h n     -> [ "kernel Elm.Kernel." ++ S.toChars (Module.kernelToString h) ++ "." ++ N.toChars n ]
    Opt.List es           -> block "List" (map ppExpr es)
    Opt.Function xs b     -> ("Function (" ++ unwords (map N.toChars xs) ++ ")") : sub (ppExpr b)
    Opt.Call f xs         -> block "Call" (ppExpr f : map ppExpr xs)
    Opt.TailCall n xs     -> block ("TailCall " ++ N.toChars n) (map (\(a, e) -> ("arg " ++ N.toChars a ++ " =") : sub (ppExpr e)) xs)
    Opt.If bs f           ->
      "If" : sub (concatMap (\(c, b) -> ("cond" : sub (ppExpr c)) ++ ("then" : sub (ppExpr b))) bs ++ ("else" : sub (ppExpr f)))
    Opt.Let d b           -> "Let" : sub (ppDef d ++ ("in" : sub (ppExpr b)))
    Opt.Destruct (Opt.Destructor n p) b ->
      ("Destruct " ++ N.toChars n ++ " = " ++ ppPath p) : sub (ppExpr b)
    Opt.Case label root d js ->
      ("Case label=" ++ N.toChars label ++ " root=" ++ N.toChars root)
        : sub (ppDecider d ++ concatMap (\(i, e) -> ("jump " ++ show i ++ ":") : sub (ppExpr e)) js)
    Opt.Accessor f        -> [ "Accessor ." ++ N.toChars f ]
    Opt.Access e f        -> block ("Access ." ++ N.toChars f) [ ppExpr e ]
    Opt.Update e fs       -> block "Update" (ppExpr e : map ppField (Map.toList fs))
    Opt.Record fs         -> block "Record" (map ppField (Map.toList fs))
    Opt.Unit              -> [ "Unit" ]
    Opt.Pair a b          -> block "Pair" [ ppExpr a, ppExpr b ]
    Opt.Triple a b c      -> block "Triple" [ ppExpr a, ppExpr b, ppExpr c ]
    Opt.Shader _ _ _      -> [ "Shader" ]


sub :: [String] -> [String]
sub =
  map ("  " ++)


block :: String -> [[String]] -> [String]
block name children =
  name : sub (concat children)


ppField :: (N.Name, Opt.Expr) -> [String]
ppField (n, e) =
  ("field " ++ N.toChars n ++ " =") : sub (ppExpr e)


ppPath :: Opt.Path -> String
ppPath path =
  case path of
    Opt.Index i p -> ppPath p ++ ".#" ++ show (Index.toMachine i)
    Opt.Field f p -> ppPath p ++ "." ++ N.toChars f
    Opt.Unbox p   -> ppPath p ++ ".unbox"
    Opt.Root n    -> N.toChars n


ppDecider :: Opt.Decider Opt.Choice -> [String]
ppDecider decider =
  case decider of
    Opt.Leaf choice ->
      case choice of
        Opt.Inline e -> "leaf" : sub (ppExpr e)
        Opt.Jump i   -> [ "leaf jump " ++ show i ]

    Opt.Chain tests s f ->
      ("chain " ++ unwords (map (\(p, t) -> ppDtPath p ++ " is " ++ ppTest t) tests))
        : sub (("success" : sub (ppDecider s)) ++ ("failure" : sub (ppDecider f)))

    Opt.FanOut p tests fallback ->
      ("fanout " ++ ppDtPath p)
        : sub (concatMap (\(t, d) -> ("on " ++ ppTest t) : sub (ppDecider d)) tests ++ ("fallback" : sub (ppDecider fallback)))


ppDtPath :: DT.Path -> String
ppDtPath path =
  case path of
    DT.Index i p -> ppDtPath p ++ ".#" ++ show (Index.toMachine i)
    DT.Unbox p   -> ppDtPath p ++ ".unbox"
    DT.Empty     -> "root"


ppTest :: DT.Test -> String
ppTest test =
  case test of
    DT.IsCtor h n i arity _ -> "ctor " ++ showHome h ++ "." ++ N.toChars n ++ " #" ++ show (Index.toMachine i) ++ "/" ++ show arity
    DT.IsCons               -> "cons"
    DT.IsNil                -> "nil"
    DT.IsTuple              -> "tuple"
    DT.IsInt i              -> "int " ++ show i
    DT.IsChr c              -> "chr " ++ show c
    DT.IsStr s              -> "str " ++ show (ES.toChars s)
    DT.IsBool b             -> "bool " ++ show b
