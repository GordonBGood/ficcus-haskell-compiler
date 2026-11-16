{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE BangPatterns, MagicHash #-}
module Type.Dump
  ( render
  , moduleLabel
  , Result(..)
  , Ctx(..)
  , mkCtx
  , defIdOf
  , calleeId
  , schemeOf
  , bindDefs
  , canonVars
  , kindList
  , defName
  , defKeyOf
  , declsToDefs
  , moduleChars
  , regionText
  )
  where


-- Ficcus milestone 2, steps 3 and 4: the `.types` dump.
--
-- Walks a Can.Module and prints, for every expression and pattern node, its
-- source region, its kind and its type; for every definition its scheme; for
-- every use of a polymorphic name the instance (which type each quantified
-- variable of the scheme has at this use). Types are shown after defaulting:
-- a variable that is neither quantified by an enclosing definition nor part of
-- one of their schemes is dead and gets its default (number becomes Int, every
-- other unresolved variable the reference class). When defaulting changed a
-- type, the raw type follows after `<=`.
--
-- The same walk is the completeness check: every node that the recorder should
-- have a key for is looked up, and a missing one is counted as a problem.


import Control.Monad (forM_, when)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import Control.Monad.State.Strict (State, execState, gets, modify')
import Data.Bits (shiftR, (.&.))
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word64)
import GHC.Word (Word64(..))

import qualified AST.Canonical as Can
import qualified AST.Constraints as Constraints
import qualified Data.Index as Index
import qualified AST.Prim.Name as N
import qualified AST.Prim.Operator as Op
import qualified AST.Prim.TypeName as T
import qualified Elm.ModuleName as ModuleName
import qualified Elm.Package as Pkg
import qualified AST.Prim.Module as Module
import qualified Reporting.Annotation as A
import qualified Ficcus.Mono.Facts as Facts
import Type.Readout
import Type.Recorder (Key(..), DefKey(..))
import qualified Type.Recorder as Recorder



-- RESULT


data Result =
  Result
    { _text :: [BS.ByteString]   -- the lines, UTF-8, without line ends
    , _problems :: Int
    , _matched :: Int
    , _matchFailed :: Int
    , _defaulted :: Int
    , _eqUses :: Int          -- direct uses of ==, /=, compare
    , _eqFunUses :: [String]  -- those whose instance type contains a function
    , _defFacts :: [Facts.DefFact]
    , _initFacts :: [Facts.InitFact]
    , _useFacts :: [Facts.UseFact]
    }



-- STATE


data W =
  W
    { _out :: [BS.ByteString]          -- reversed; strict, so a line costs its bytes and not a String
    , _bad :: Int
    , _ok :: Int
    , _failed :: Int
    , _defaultedCount :: Int
    , _eqCount :: Int
    , _eqFuns :: [String]
    , _seen :: Set.Set Key
    , _display :: Map.Map String String
    , _usedNames :: Set.Set String
    , _refs :: Map.Map String (Set.Set String)   -- top level definition id -> top level definitions of the module it mentions
    , _fDefs :: [Facts.DefFact]                  -- reversed
    , _fInits :: [Facts.InitFact]                -- reversed
    , _fUses :: [Facts.UseFact]                  -- reversed
    }


type M a = State W a


data Ctx =
  Ctx
    { _typed :: Typed
    , _scope :: Set.Set String
    , _vals :: Map.Map N.Name (Either DefKey Key)   -- a definition, or a name bound by a let pattern
    , _depth :: Int
    , _home :: ModuleName.Canonical
    , _tops :: Set.Set DefKey                        -- the top level definitions of the module
    , _groups :: Map.Map DefKey (String, Bool)      -- binding group of a definition: id, recursive
    , _topDef :: String                              -- id of the top level definition being walked
    , _inGroups :: Set.Set String                    -- groups whose definitions are being walked
    , _owned :: Map.Map String String               -- scheme variable -> token naming its owner definition and index
    }



-- RENDER


render :: Can.Module -> Typed -> Result
render (Can.Module home _ _ decls unions _ _ _) typed =
  let
    topDefs = declsToDefs decls
    ctx = mkCtx home decls typed
    start = W [] 0 0 0 0 0 [] Set.empty Map.empty Set.empty Map.empty [] [] []
    w = execState (walkModule ctx home unions topDefs) start
    unvisited = Map.size (_nodes typed) - Set.size (_seen w)
    extra =
      if unvisited /= 0
        then [ "!! " ++ show unvisited ++ " recorded node(s) were not visited by the dump walk" ]
        else []
  in
  Result
    { _text = reverse (_out w) ++ map packLine extra
    , _problems = _bad w + (if unvisited /= 0 then 1 else 0)
    , _matched = _ok w
    , _matchFailed = _failed w
    , _defaulted = _defaultedCount w
    , _eqUses = _eqCount w
    , _eqFunUses = reverse (_eqFuns w)
    , _defFacts = reverse (_fDefs w)
    , _initFacts = reverse (_fInits w)
    , _useFacts = reverse (_fUses w)
    }


-- the context of a module's top level (also used by the specializer)
mkCtx :: ModuleName.Canonical -> Can.Decls -> Typed -> Ctx
mkCtx home decls typed =
  let
    topDefs = declsToDefs decls
    vals = Map.fromList [ (defName d, Left (defKeyOf d)) | d <- topDefs ]
    ctx0 = Ctx typed Set.empty vals 0 home (Set.fromList [ defKeyOf d | d <- topDefs ]) Map.empty "" Set.empty Map.empty
  in
  ctx0 { _groups = groupsOfDecls ctx0 decls }


walkModule :: Ctx -> ModuleName.Canonical -> Map.Map T.Name Can.Union -> [Can.Def] -> M ()
walkModule ctx home unions defs =
  do  emit (ctx { _depth = 0 }) ("module " ++ moduleChars home)
      walkUnions ctx home unions
      forM_ defs $ \def ->
        do  modify' (\w -> w { _display = Map.empty, _usedNames = Set.empty })
            walkDef ctx def
      emitInitOrder ctx defs


-- package and module of a canonical module, e.g. `elm/core:List`
moduleLabel :: Can.Module -> String
moduleLabel (Can.Module home _ _ _ _ _ _ _) = moduleChars home


moduleChars :: ModuleName.Canonical -> String
moduleChars (ModuleName.Canonical pkg name) =
  Pkg.toChars pkg ++ ":" ++ Module.toChars name


declsToDefs :: Can.Decls -> [Can.Def]
declsToDefs decls =
  case decls of
    Can.Declare d rest -> d : declsToDefs rest
    Can.DeclareRec d ds rest -> d : ds ++ declsToDefs rest
    Can.SaveTheEnvironment -> []


defName :: Can.Def -> N.Name
defName def =
  case def of
    Can.Def (A.At _ n) _ _ -> n
    Can.TypedDef (A.At _ n) _ _ _ _ -> n


defKeyOf :: Can.Def -> DefKey
defKeyOf def =
  case def of
    Can.Def (A.At r n) _ _ -> Recorder.defKey r n
    Can.TypedDef (A.At r n) _ _ _ _ -> Recorder.defKey r n



-- OUTPUT


emit :: Ctx -> String -> M ()
emit ctx line =
  let !packed = packLine (replicate (2 * _depth ctx) ' ' ++ line)
  in modify' (\w -> w { _out = packed : _out w })


packLine :: String -> BS.ByteString
packLine = BL.toStrict . BB.toLazyByteString . BB.stringUtf8


problem :: Ctx -> String -> M ()
problem ctx msg =
  do  modify' (\w -> w { _bad = _bad w + 1 })
      emit ctx ("!! " ++ msg)


regionText :: A.Region -> String
regionText (A.Region s e) =
  let
    (sr, sc) = rowCol (W64# s)
    (er, ec) = rowCol (W64# e)
  in
  show sr ++ ":" ++ show sc ++ "-" ++ show er ++ ":" ++ show ec


rowCol :: Word64 -> (Word64, Word64)
rowCol w =
  ( (w `shiftR` 32) + 1, (w .&. 0xFFFFFFFF) + 1 )



-- DEFINITIONS


walkDef :: Ctx -> Can.Def -> M ()
walkDef ctx def =
  let
    (region, name, argPatterns, body) =
      case def of
        Can.Def (A.At r n) args b -> (r, n, args, b)
        Can.TypedDef (A.At r n) _ args b _ -> (r, n, map fst args, b)
  in
  case Map.lookup (defKeyOf def) (_defs (_typed ctx)) of
    Nothing ->
      problem ctx ("no scheme recorded for definition " ++ N.toChars name ++ " at " ++ regionText region)

    Just scheme ->
      do  shown <- showScheme ctx scheme
          let did = defIdOf ctx (defKeyOf def)
          sigText <- sigOf ctx scheme
          emit ctx ("def " ++ N.toChars name ++ " :: " ++ shown ++ "    [" ++ regionText region ++ "]"
                    ++ "   id: " ++ did ++ "   sig: " ++ sigText ++ "   kinds: " ++ kindsText scheme ++ groupText ctx def)
          modify' (\w -> w { _fDefs = Facts.DefFact did (kindList scheme) False : _fDefs w })
          let owned' = List.foldl' (\m (u, i) -> Map.insertWith (\_ old -> old) u (varToken did i) m) (_owned ctx) (canonVars scheme)
          let inner = ctx { _scope = Set.union (_scope ctx) (Set.fromList (map fst (tvars scheme))), _depth = _depth ctx + 1, _owned = owned'
                          , _topDef = if Set.member (defKeyOf def) (_tops ctx) then did else _topDef ctx
                          , _inGroups = case Map.lookup (defKeyOf def) (_groups ctx) of { Just (gid, True) -> Set.insert gid (_inGroups ctx); _ -> _inGroups ctx } }
          mapM_ (walkPattern inner) argPatterns
          walkExpr inner body


-- the scheme of a definition is shown without defaulting: its variables are the
-- quantified ones
showScheme :: Ctx -> TType -> M String
showScheme _ scheme =
  showType scheme



-- EXPRESSIONS


walkExpr :: Ctx -> Can.Expr -> M ()
walkExpr ctx (A.At region e) =
  do  when (Recorder.isRecordedExpr e) (nodeLine ctx region e)
      let sub = ctx { _depth = _depth ctx + 1 }
      case e of
        Can.VarLocal _ -> return ()
        Can.VarTopLevel _ _ -> return ()
        Can.VarKernel _ _ -> return ()
        Can.VarForeign _ _ _ -> return ()
        Can.VarCtor _ _ _ _ _ -> return ()
        Can.VarDebug _ _ _ -> return ()
        Can.VarOperator _ _ _ _ -> return ()
        Can.Chr _ -> return ()
        Can.Str _ -> return ()
        Can.Int _ -> return ()
        Can.Float _ -> return ()
        Can.List es -> mapM_ (walkExpr sub) es
        Can.Negate x -> walkExpr sub x
        Can.Binop _ _ _ _ l r -> walkExpr sub l >> walkExpr sub r
        Can.Lambda pats body -> mapM_ (walkPattern sub) pats >> walkExpr sub body
        Can.Call f args -> walkExpr sub f >> mapM_ (walkExpr sub) args
        Can.If branches final ->
          do  forM_ branches $ \(c, b) -> walkExpr sub c >> walkExpr sub b
              walkExpr sub final
        Can.Let def body ->
          do  let ctx1 = bindDefs ctx False [def]
              walkDef ctx1 def
              walkExpr ctx1 body
        Can.LetRec defs body ->
          do  let ctx1 = bindDefs ctx True defs
              mapM_ (walkDef ctx1) defs
              walkExpr ctx1 body
        Can.LetDestruct pat x body ->
          do  walkPattern ctx pat
              walkExpr ctx x
              -- names bound by a let pattern are generalized like definitions
              let binders = Map.fromList (map (fmap Right) (patBinders pat))
              walkExpr (ctx { _vals = Map.union binders (_vals ctx) }) body
        Can.Case x branches ->
          do  walkExpr sub x
              forM_ branches $ \(Can.CaseBranch pat b) -> walkPattern sub pat >> walkExpr sub b
        Can.Accessor _ -> return ()
        Can.Access x _ -> walkExpr sub x
        Can.Update _ x fields ->
          do  walkExpr sub x
              forM_ (Map.elems fields) $ \(Can.FieldUpdate _ v) -> walkExpr sub v
        Can.Record fields -> mapM_ (walkExpr sub) (Map.elems fields)
        Can.Unit -> return ()
        Can.Pair a b -> walkExpr sub a >> walkExpr sub b
        Can.Triple a b c -> walkExpr sub a >> walkExpr sub b >> walkExpr sub c
        Can.Shader _ _ -> return ()


-- the names a pattern binds with the key of the node that carries their type
patBinders :: Can.Pattern -> [(N.Name, Key)]
patBinders (A.At region p) =
  case p of
    Can.PVar n -> [ (n, Recorder.patKey region p) ]
    Can.PAlias inner n -> (n, Recorder.patKey region p) : patBinders inner
    Can.PPair a b -> patBinders a ++ patBinders b
    Can.PTriple a b c -> patBinders a ++ patBinders b ++ patBinders c
    Can.PList ps -> concatMap patBinders ps
    Can.PCons h t -> patBinders h ++ patBinders t
    Can.PCtor {} -> concatMap (\(Can.PatternCtorArg _ _ a) -> patBinders a) (Can._p_args p)
    _ -> []


bindDefs :: Ctx -> Bool -> [Can.Def] -> Ctx
bindDefs ctx isRec defs =
  ctx
    { _vals = List.foldl' (\m d -> Map.insert (defName d) (Left (defKeyOf d)) m) (_vals ctx) defs
    , _groups = List.foldl' (\m d -> Map.insert (defKeyOf d) (groupId, isRec) m) (_groups ctx) defs
    }
  where
    groupId = case map defKeyOf defs of { [] -> ""; keys -> defIdOf ctx (minimum keys) }


-- BINDING GROUPS (stage (ii) step 7, item 5)
--
-- A group is a set of mutually recursive definitions (Elm's strongly connected
-- component), or one definition that is not recursive. Its id is the id of the member that comes first in the
-- source. A `def` line says `group: <id> rec|nonrec` and whether the definition has
-- an annotation (`ann`) or is inferred. A use of a definition of this module says
-- `use: rec` when it is inside the definitions of its own group: the use is at the
-- definition being checked, not a fresh instance (also for an annotated definition: Elm
-- gives it its annotation, with the type variables rigid, so there is no polymorphic
-- recursion; the subst of such a use is empty), or `use: gen` outside it (an ordinary use of the generalized
-- scheme, with its own subst).


groupsOfDecls :: Ctx -> Can.Decls -> Map.Map DefKey (String, Bool)
groupsOfDecls ctx decls =
  case decls of
    Can.Declare d rest -> Map.insert (defKeyOf d) (defIdOf ctx (defKeyOf d), False) (groupsOfDecls ctx rest)
    Can.DeclareRec d ds rest ->
      let gid = defIdOf ctx (minimum (map defKeyOf (d : ds)))
      in List.foldl' (\m x -> Map.insert (defKeyOf x) (gid, True) m) (groupsOfDecls ctx rest) (d : ds)
    Can.SaveTheEnvironment -> Map.empty


groupText :: Ctx -> Can.Def -> String
groupText ctx def =
  case Map.lookup (defKeyOf def) (_groups ctx) of
    Nothing -> ""
    Just (gid, isRec) ->
      "   group: " ++ gid ++ (if isRec then " rec" else " nonrec")
      ++ (case def of { Can.TypedDef {} -> " ann"; Can.Def {} -> " inferred" })


useGroupText :: Ctx -> Can.Expr_ -> String
useGroupText ctx e =
  case e of
    Can.VarLocal name -> byName name
    Can.VarTopLevel _ name -> byName name
    _ -> ""
  where
    byName name =
      case Map.lookup name (_vals ctx) of
        Just (Left key) ->
          case Map.lookup key (_groups ctx) of
            Just (gid, _) -> if Set.member gid (_inGroups ctx) then "   use: rec" else "   use: gen"
            Nothing -> ""
        _ -> ""


nodeLine :: Ctx -> A.Region -> Can.Expr_ -> M ()
nodeLine ctx region e =
  do  let key = Recorder.exprKey region e
      modify' (\w -> w { _seen = Set.insert key (_seen w) })
      case Map.lookup key (_nodes (_typed ctx)) of
        Nothing ->
          problem ctx ("missing type for " ++ Recorder.exprKind e ++ " at " ++ regionText region)

        Just raw ->
          do  noteTopRef ctx e
              (shown, extra) <- typeText ctx raw
              inst <- instanceText ctx e raw
              emit ctx (regionText region ++ " " ++ Recorder.exprKind e ++ " :: " ++ shown ++ extra ++ calleeText ctx e ++ useGroupText ctx e ++ inst)



-- PATTERNS


walkPattern :: Ctx -> Can.Pattern -> M ()
walkPattern ctx (A.At region p) =
  do  let key = Recorder.patKey region p
      modify' (\w -> w { _seen = Set.insert key (_seen w) })
      case Map.lookup key (_nodes (_typed ctx)) of
        Nothing ->
          problem ctx ("missing type for pattern " ++ Recorder.patKind p ++ " at " ++ regionText region)

        Just raw ->
          do  (shown, extra) <- typeText ctx raw
              emit ctx (regionText region ++ " " ++ Recorder.patKind p ++ varName p ++ " :: " ++ shown ++ extra)
      let sub = ctx { _depth = _depth ctx + 1 }
      case p of
        Can.PAnything -> return ()
        Can.PVar _ -> return ()
        Can.PRecord _ -> return ()
        Can.PAlias inner _ -> walkPattern sub inner
        Can.PUnit -> return ()
        Can.PPair a b -> walkPattern sub a >> walkPattern sub b
        Can.PTriple a b c -> walkPattern sub a >> walkPattern sub b >> walkPattern sub c
        Can.PList ps -> mapM_ (walkPattern sub) ps
        Can.PCons h t -> walkPattern sub h >> walkPattern sub t
        Can.PBool _ _ -> return ()
        Can.PChr _ -> return ()
        Can.PStr _ -> return ()
        Can.PInt _ -> return ()
        Can.PCtor {} -> mapM_ (\(Can.PatternCtorArg _ _ a) -> walkPattern sub a) (Can._p_args p)
  where
    varName pat =
      case pat of
        Can.PVar n -> " " ++ N.toChars n
        Can.PAlias _ n -> " as " ++ N.toChars n
        Can.PRecord ns -> " {" ++ List.intercalate "," (map N.toChars ns) ++ "}"
        Can.PCtor {} -> " " ++ N.toChars (Can._p_name pat)
        _ -> ""



-- TYPES AS TEXT


-- the type after defaulting, and the raw type when defaulting changed it
typeText :: Ctx -> TType -> M (String, String)
typeText ctx raw =
  do  let dead n = not (Set.member n (_scope ctx))
      let defaulted = applyDefault dead raw
      shown <- showType defaulted
      if length (filter dead (map fst (tvars raw))) == 0
        then return (shown, "")
        else
          do  modify' (\w -> w { _defaultedCount = _defaultedCount w + 1 })
              rawShown <- showType raw
              return (shown, "   <= " ++ rawShown)


showType :: TType -> M String
showType tipe = showPrec (0 :: Int) tipe


showPrec :: Int -> TType -> M String
showPrec prec tipe =
  case tipe of
    TCon _ name args ->
      do  as <- mapM (showPrec 2) args
          let text = unwords (N.toChars (T.nameToName name) : as)
          return (if prec >= 2 && not (null args) then "(" ++ text ++ ")" else text)

    TFun a b ->
      do  x <- showPrec 1 a
          y <- showPrec 0 b
          let text = x ++ " -> " ++ y
          return (if prec >= 1 then "(" ++ text ++ ")" else text)

    TRecord fields ext ->
      do  fs <- mapM (\(n, t) -> (\s -> N.toChars n ++ " : " ++ s) <$> showPrec 0 t) (Map.toList fields)
          extText <- maybe (return "") (\t -> (\s -> s ++ " | ") <$> showPrec 0 t) ext
          return $
            if null fs && null extText
              then "{}"
              else "{ " ++ extText ++ List.intercalate ", " fs ++ " }"

    TUnit -> return "()"

    TPair a b ->
      do  x <- showPrec 0 a
          y <- showPrec 0 b
          return ("( " ++ x ++ ", " ++ y ++ " )")

    TTriple a b c ->
      do  x <- showPrec 0 a
          y <- showPrec 0 b
          z <- showPrec 0 c
          return ("( " ++ x ++ ", " ++ y ++ ", " ++ z ++ " )")

    TVar name kind rigid -> displayName name kind rigid

    TAlias _ name args _ ->
      do  as <- mapM (showPrec 2 . snd) args
          let text = unwords (N.toChars (T.nameToName name) : as)
          return (if prec >= 2 && not (null args) then "(" ++ text ++ ")" else text)

    TRef kind -> return (if kind == KAny then "ref" else "ref(" ++ kindWord kind ++ ")")

    TError -> return "<error>"


kindWord :: Kind -> String
kindWord kind =
  case kind of
    KAny -> "any"
    KNumber -> "number"
    KComparable -> "comparable"
    KAppendable -> "appendable"
    KCompAppend -> "compappend"


-- variables are shown by their base name, made distinct inside one top level definition
displayName :: String -> Kind -> Bool -> M String
displayName unique kind _ =
  do  known <- gets (Map.lookup unique . _display)
      case known of
        Just shown -> return shown
        Nothing ->
          do  used <- gets _usedNames
              let base = case takeWhile (/= '#') unique of { "" -> kindWord kind; b -> b }
              let candidates = base : [ base ++ show i | i <- [1 :: Int ..] ]
              let chosen = List.foldr const base (dropWhile (`Set.member` used) candidates)
              modify' (\w -> w { _display = Map.insert unique chosen (_display w), _usedNames = Set.insert chosen (_usedNames w) })
              return chosen



-- CALLEE IDENTITY (Ficcus stage (ii) step 7, item 1)
--
-- Every use of a named value says which definition it uses: `callee: pkg:Module.name`
-- (home module and name; for an operator the function it resolves to). A name bound
-- by a let or at top level of the current module has the same form with the current
-- module; a name bound by a pattern has no callee. The identity is the pair, the
-- region of the definition is in the `def` line of its own module.


calleeText :: Ctx -> Can.Expr_ -> String
calleeText ctx e =
  case calleeId ctx e of
    Nothing -> ""
    Just cid -> "   callee: " ++ cid


calleeOf :: Ctx -> Can.Expr_ -> Maybe (ModuleName.Canonical, N.Name)
calleeOf ctx e =
  case e of
    Can.VarTopLevel home name -> Just (home, name)
    Can.VarForeign home name _ -> Just (home, name)
    Can.VarDebug home name _ -> Just (home, name)
    Can.VarCtor _ home name _ _ -> Just (home, name)
    Can.VarOperator _ home name _ -> Just (home, name)
    Can.Binop _ home name _ _ _ -> Just (home, name)
    Can.VarLocal name ->
      case Map.lookup name (_vals ctx) of
        Just (Left _) -> Just (_home ctx, name)
        _ -> Nothing
    _ -> Nothing


-- the identity of a definition of this module: top level `Module.name`, local
-- `Module.name@row:col` (position of the name, so that equal names in different
-- scopes differ)
defIdOf :: Ctx -> DefKey -> String
defIdOf ctx key@(DefKey s _ n) =
  moduleChars (_home ctx) ++ "." ++ N.toChars n ++
    (if Set.member key (_tops ctx) then "" else "@" ++ show r ++ ":" ++ show c)
  where (r, c) = rowCol s


-- the id of the callee at a use, as in `callee:` but exact for local definitions
calleeId :: Ctx -> Can.Expr_ -> Maybe String
calleeId ctx e =
  case e of
    Can.VarLocal name ->
      case Map.lookup name (_vals ctx) of
        Just (Left key) -> Just (defIdOf ctx key)
        _ -> Nothing
    Can.VarTopLevel _ name ->
      case Map.lookup name (_vals ctx) of
        Just (Left key) -> Just (defIdOf ctx key)
        _ -> Nothing
    -- VarDebug carries the home of the module that uses it, not of Debug
    Can.VarDebug _ name _ -> Just ("elm/core:Debug." ++ N.toChars name)
    _ -> fmap (\(home, name) -> moduleChars home ++ "." ++ N.toChars name) (calleeOf ctx e)


-- SCHEMES AS DATA (stage (ii) step 7, item 2)
--
-- The variables of a scheme are numbered v0, v1, ... in order of first occurrence,
-- so the numbering depends on the scheme only and is the same at the definition
-- (`def` line: id, sig, kinds) and at every use (`subst:` line). A variable that an
-- enclosing definition owns is written `<<ownerId|vN>>` wherever it occurs.
-- Kinds: any, number, comparable, appendable, compappend, or row (the extension
-- variable of a record type).


canonVars :: TType -> [(String, Int)]
canonVars scheme = zip (List.nub (map fst (tvars scheme))) [0 ..]


-- the owner definition id and variable index of a token `<<id|vN>>`
parseToken :: String -> Maybe (String, Int)
parseToken tok =
  case reverse (drop 2 (reverse (drop 2 tok))) of
    inner ->
      let (revIx, revId) = break (== 'v') (reverse inner)
      in case (reverse revIx, revId) of
           (digits@(_ : _), 'v' : '|' : restId) | all (`elem` "0123456789") digits -> Just (reverse restId, read digits)
           _ -> Nothing


varToken :: String -> Int -> String
varToken did i = "<<" ++ did ++ "|v" ++ show i ++ ">>"


rowVarNames :: TType -> Set.Set String
rowVarNames tipe =
  case tipe of
    TCon _ _ args -> Set.unions (map rowVarNames args)
    TFun a b -> Set.union (rowVarNames a) (rowVarNames b)
    TRecord fields ext ->
      Set.unions (maybe Set.empty extVars ext : map rowVarNames (Map.elems fields))
    TPair a b -> Set.union (rowVarNames a) (rowVarNames b)
    TTriple a b c -> Set.unions [rowVarNames a, rowVarNames b, rowVarNames c]
    TAlias _ _ _ real -> rowVarNames real
    _ -> Set.empty
  where
    extVars t =
      case t of
        TVar n _ _ -> Set.singleton n
        other -> rowVarNames other


kindsText :: TType -> String
kindsText scheme =
  List.intercalate "," [ "v" ++ show i ++ ":" ++ k | (i, k) <- zip [0 :: Int ..] (kindList scheme) ]


-- the kind of each quantified variable v0, v1, ...
kindList :: TType -> [String]
kindList scheme =
  let rows = rowVarNames scheme
      kindOf u = case [ k | (n, k) <- tvars scheme, n == u ] of { k : _ -> k; [] -> KAny }
  in [ if Set.member u rows then "row" else kindWord (kindOf u) | (u, _) <- canonVars scheme ]


-- run a rendering with some variables shown under given names; the names chosen
-- for other variables meanwhile are kept
withNames :: [(String, String)] -> M a -> M a
withNames pairs act =
  do  saved <- gets _display
      modify' (\w -> w { _display = Map.union (Map.fromList pairs) (_display w) })
      r <- act
      modify' (\w -> w { _display = List.foldl' (\m (u, _) -> maybe (Map.delete u m) (\o -> Map.insert u o m) (Map.lookup u saved)) (_display w) pairs })
      return r


-- the names a scheme is shown under: v<i> for its own variables, the owner's token for others
schemeNames :: Ctx -> TType -> [(String, String)]
schemeNames ctx scheme =
  [ (u, maybe ("v" ++ show i) id (Map.lookup u (_owned ctx))) | (u, i) <- canonVars scheme ]


sigOf :: Ctx -> TType -> M String
sigOf ctx scheme = withNames (schemeNames ctx scheme) (showType scheme)


sigHash :: String -> String
sigHash text =
  let h = List.foldl' (\acc c -> (acc * 33 + fromEnum c) `mod` 4294967291) (5381 :: Int) text
  in showHex8 h
  where
    showHex8 n = [ "0123456789abcdef" !! ((n `div` (16 ^ k)) `mod` 16) | k <- [7, 6 .. 0 :: Int] ]



-- INSTANCES AT USES


instanceText :: Ctx -> Can.Expr_ -> TType -> M String
instanceText ctx e raw =
  case schemeOf ctx e raw of
    Nothing ->
      return ""

    Just (scheme, inst) ->
      case matchT scheme inst of
        Left err ->
          do  modify' (\w -> w { _failed = _failed w + 1, _bad = _bad w + 1 })
              return ("   !! instance match failed: " ++ err)

        Right subst ->
          do  modify' (\w -> w { _ok = _ok w + 1 })
              let dead n = not (Set.member n (_scope ctx))
              parts <- mapM (bindingText dead) (Map.toList subst)
              let real = [ p | Just p <- parts ]
              case equalityUse e of
                Nothing -> return ()
                Just opName ->
                  do  shown <- mapM showType (Map.elems subst)
                      let atFun = any hasFunction (Map.elems subst)
                      modify' (\w -> w { _eqCount = _eqCount w + 1
                                       , _eqFuns = if atFun then (opName ++ " " ++ List.intercalate "," shown) : _eqFuns w else _eqFuns w })
              substPart <- substText scheme subst
              return ((if null real then "" else "   instance: " ++ List.intercalate ", " real) ++ substPart)
  where
    -- the substitution as data, in the callee's canonical variable names
    substText scheme subst =
      do  let ownedNames = [ (u, tok) | (u, tok) <- Map.toList (_owned ctx) ]
          let dead n = not (Set.member n (_scope ctx))
          sig <- sigOf sigCtx scheme
          entries <-
            mapM
              (\(u, i) ->
                  case Map.lookup u subst of
                    Nothing -> return Nothing
                    Just (TVar other _ _) | other == u && not isRecUse -> return Nothing
                    Just value ->
                      do  shown <- withNames ownedNames (showType (applyDefault dead value))
                          return (Just ("v" ++ show i ++ " := " ++ shown)))
              (canonVars scheme)
          let present = [ x | Just x <- entries ]
          let factBinds =
                [ (i, owners)
                | (u, i) <- canonVars scheme
                , Just value <- [Map.lookup u subst]
                , not (isIdentity u value && not isRecUse)
                , let owners = List.nub [ o | (n, _) <- tvars (applyDefault dead value), Just tok <- [Map.lookup n (_owned ctx)], Just o <- [parseToken tok] ]
                ]
          case (calleeId ctx e, present) of
            (Just callee, _ : _) -> modify' (\w -> w { _fUses = Facts.UseFact callee factBinds : _fUses w })
            _ -> return ()
          return (if null present then "" else "   sig#: " ++ sigHash sig ++ "   subst: " ++ List.intercalate ", " present)

    -- A1: a use inside the callee's own group is at the group's own variables. Its subst is
    -- written in full (identity entries too): the callee's variable is the owner's (`<<owner|vK>>`).
    -- A variable of the group that the owner's signature does not contain is dead in the owner and
    -- is defaulted like any dead variable (`ref` or `Int`, by kind).
    isRecUse = useGroupText ctx e == "   use: rec"

    -- the signature is shown as on the callee's own `def` line: there the variables of the group's
    -- members were not yet owned by them, so inside the group they are v0, v1, ... again
    sigCtx =
      if not isRecUse then ctx else
        let members = case calleeGroupId of
              Nothing -> Set.empty
              Just gid -> Set.fromList [ defIdOf ctx k | (k, (g, _)) <- Map.toList (_groups ctx), g == gid ]
            ownedByMember tok = maybe False (\(o, _) -> Set.member o members) (parseToken tok)
        in ctx { _owned = Map.filter (not . ownedByMember) (_owned ctx) }

    calleeGroupId =
      case e of
        Can.VarLocal name -> byName name
        Can.VarTopLevel _ name -> byName name
        _ -> Nothing
      where
        byName name =
          case Map.lookup name (_vals ctx) of
            Just (Left key) -> fmap fst (Map.lookup key (_groups ctx))
            _ -> Nothing

    isIdentity u value = case value of { TVar other _ _ -> other == u; _ -> False }

    bindingText dead (name, value) =
      case value of
        TVar other _ _ | other == name -> return Nothing
        _ ->
          do  shown <- showType (applyDefault dead value)
              let mark = if any dead (map fst (tvars value)) then " (defaulted)" else ""
              keyName <- if '#' `elem` name then displayName name KAny False else return name
              return (Just (keyName ++ " := " ++ shown ++ mark))

    _unused = raw


-- the scheme of the name used at this node, and the type it is used at
schemeOf :: Ctx -> Can.Expr_ -> TType -> Maybe (TType, TType)
schemeOf ctx e raw =
  case e of
    Can.VarLocal name -> local name
    Can.VarTopLevel _ name -> local name
    Can.VarForeign _ _ ann -> Just (constrained ann)
    Can.VarCtor _ _ _ _ ann -> Just (annotation ann, raw)
    Can.VarDebug _ _ ann -> Just (annotation ann, raw)
    Can.VarOperator _ _ _ ann -> Just (annotation ann, raw)
    Can.Binop _ _ _ ann l r ->
      do  lt <- nodeType l
          rt <- nodeType r
          Just (annotation ann, TFun lt (TFun rt raw))
    _ -> Nothing
  where
    local name =
      do  source <- Map.lookup name (_vals ctx)
          scheme <-
            case source of
              Left key -> Map.lookup key (_defs (_typed ctx))
              Right key -> Map.lookup key (_nodes (_typed ctx))
          Just (scheme, raw)

    annotation (Can.Forall _ tipe) = canToTType tipe

    -- Ficcus (ATTACH A2): the scheme of a constrained function is its type with the hidden parameters (the type
    -- its definition has); the instance gets the types of the members at this use in front
    constrained ann@(Can.Forall _ tipe) =
      case Constraints.unwrap tipe of
        Nothing -> (annotation ann, raw)
        Just (real, required) ->
          let
            realScheme = canToTType real
            members = [ canToTType t | Constraints.Required _ _ t <- required ]
            subst = either (const Map.empty) id (matchT realScheme raw)
          in
          (foldr TFun realScheme members, foldr (\m acc -> TFun (substT subst m) acc) raw members)

    nodeType (A.At r x) = Map.lookup (Recorder.valueKey r x) (_nodes (_typed ctx))   -- valueKey: an operand may be a `let`


-- replace the variables of a scheme by what they are bound to
substT :: Subst -> TType -> TType
substT s t =
  case t of
    TCon h n args -> TCon h n (map go args)
    TFun a b -> TFun (go a) (go b)
    TRecord fields ext -> TRecord (Map.map go fields) (fmap go ext)
    TUnit -> t
    TPair a b -> TPair (go a) (go b)
    TTriple a b c -> TTriple (go a) (go b) (go c)
    TVar n _ _ -> Map.findWithDefault t n s
    TAlias h n args real -> TAlias h n [ (v, go x) | (v, x) <- args ] (go real)
    TRef _ -> t
    TError -> t
  where
    go = substT s


-- a direct use of ==, /= or compare (Basics)
equalityUse :: Can.Expr_ -> Maybe String
equalityUse e =
  case e of
    Can.Binop op home _ _ _ _ -> if isBasics home && Op.toChars op `elem` ["==", "/="] then Just (Op.toChars op) else Nothing
    Can.VarOperator op home _ _ -> if isBasics home && Op.toChars op `elem` ["==", "/="] then Just (Op.toChars op) else Nothing
    Can.VarForeign home name _ -> if isBasics home && N.toChars name == "compare" then Just "compare" else Nothing
    _ -> Nothing
  where
    isBasics home = moduleChars home == "elm/core:Basics"


hasFunction :: TType -> Bool
hasFunction t =
  case t of
    TFun _ _ -> True
    TCon _ _ args -> any hasFunction args
    TRecord fields ext -> any hasFunction (Map.elems fields) || maybe False hasFunction ext
    TPair a b -> hasFunction a || hasFunction b
    TTriple a b c -> any hasFunction [a, b, c]
    TAlias _ _ _ inner -> hasFunction inner
    _ -> False



-- CONSTRUCTOR FIELD TYPES (stage (ii) step 7, item 4)
--
-- Every custom type of the module: its id, number of parameters and constructors, and
-- Elm's own classification of its layout (normal, enum: no constructor has fields,
-- unbox: one constructor with one field). Every constructor: id (the `callee:` of its
-- uses), tag, arity, the type of each field, and its scheme `f1 -> .. -> T a b` with
-- the variables numbered v0, v1, .. by first occurrence, as for definitions; the
-- parameters of the type all occur in the result, so a phantom parameter is numbered
-- too. A use of the constructor has `sig#` and `subst` in these names.


walkUnions :: Ctx -> ModuleName.Canonical -> Map.Map T.Name Can.Union -> M ()
walkUnions ctx home unions =
  forM_ (Map.toList unions) $ \(tname, Can.Union vars alts numAlts opts) ->
    do  modify' (\w -> w { _display = Map.empty, _usedNames = Set.empty })
        let typeName = N.toChars (T.nameToName tname)
        let layout = case opts of { Can.Normal -> "normal"; Can.Enum -> "enum"; Can.Unbox -> "unbox" }
        emit ctx ("type " ++ typeName ++ "   id: " ++ moduleChars home ++ "." ++ typeName
                  ++ "   params: " ++ show (length vars) ++ "   ctors: " ++ show numAlts ++ "   layout: " ++ layout)
        let result = canToTType (Can.TType home tname (map Can.TVar vars))
        forM_ alts $ \(Can.Ctor cname index arity fields) ->
          do  let fieldTypes = map canToTType fields
              let scheme = foldr TFun result fieldTypes
              let names = [ (u, "v" ++ show i) | (u, i) <- canonVars scheme ]
              shownFields <- withNames names (mapM showType fieldTypes)
              sig <- withNames names (showType scheme)
              modify' (\w -> w { _fDefs = Facts.DefFact (moduleChars home ++ "." ++ N.toChars cname) (kindList scheme) True : _fDefs w })
              emit (ctx { _depth = _depth ctx + 1 })
                ("ctor " ++ N.toChars cname ++ "   id: " ++ moduleChars home ++ "." ++ N.toChars cname
                 ++ "   tag: " ++ show (Index.toMachine index) ++ "   arity: " ++ show arity
                 ++ "   fields: " ++ List.intercalate " ;; " shownFields
                 ++ "   sig: " ++ sig ++ "   kinds: " ++ kindsText scheme)



-- INITIALISATION ORDER OF TOP LEVEL VALUES (stage (ii) step 7, item 7)
--
-- Elm sorts the declarations of a module by their dependencies (Canonicalize: strongly
-- connected components, dependencies first); that order is the one in `Can.Decls` and
-- the one given here (`init: i`, from 0). `kind` is `value` for a definition without
-- arguments (it is evaluated once, when the module is initialised) and `function` for
-- one with arguments. `reads` are the top level definitions of this module mentioned
-- in its body (including local definitions inside it), `needs` the top level *values*
-- of this module that have to be initialised before it can be evaluated: the values
-- reached through `reads`, also through functions (a function called while a value is
-- initialised reads values too). A value with a non-empty `needs` has `init-dep: yes`.
-- Values of other modules are initialised earlier, module by module.


noteTopRef :: Ctx -> Can.Expr_ -> M ()
noteTopRef ctx e =
  case e of
    Can.VarTopLevel _ _ ->
      case (calleeId ctx e, _topDef ctx) of
        (Just target, from) | not (null from) && target /= from ->
          modify' (\w -> w { _refs = Map.insertWith Set.union from (Set.singleton target) (_refs w) })
        _ -> return ()
    _ -> return ()


emitInitOrder :: Ctx -> [Can.Def] -> M ()
emitInitOrder ctx defs =
  do  refs <- gets _refs
      let entries = [ (defIdOf ctx (defKeyOf d), isValue d, d) | d <- defs ]
      let valueIds = Set.fromList [ i | (i, True, _) <- entries ]
      let readsOf i = Map.findWithDefault Set.empty i refs
      let reach i = go (Set.empty :: Set.Set String) [i]
            where
              go seen [] = seen
              go seen (x : rest) =
                let new = Set.toList (Set.difference (readsOf x) seen)
                in go (List.foldl' (flip Set.insert) seen new) (new ++ rest)
      let order = Map.fromList (zip [ i | (i, _, _) <- entries ] [0 :: Int ..])
      let byOrder = List.sortOn (\x -> Map.findWithDefault 0 x order) . Set.toList
      forM_ (zip [0 :: Int ..] entries) $ \(n, (i, value, d)) ->
        do  let needs = Set.filter (/= i) (Set.intersection valueIds (reach i))
            modify' (\w -> w { _fInits = Facts.InitFact i n value (byOrder needs) (value && not (Set.null needs))
                                         (case Map.lookup (defKeyOf d) (_groups ctx) of { Just (gid, True) -> Just gid; _ -> Nothing }) : _fInits w })
            emit ctx ("init: " ++ show n ++ "   id: " ++ i ++ "   kind: " ++ (if value then "value" else "function")
                      ++ "   reads: " ++ List.intercalate "," (byOrder (readsOf i))
                      ++ "   needs: " ++ List.intercalate "," (byOrder needs)
                      ++ (if value then "   init-dep: " ++ (if Set.null needs then "no" else "yes") else "")
                      ++ groupSuffix d)
  where
    isValue d = case d of { Can.Def _ args _ -> null args; Can.TypedDef _ _ args _ _ -> null args }
    groupSuffix d = case Map.lookup (defKeyOf d) (_groups ctx) of { Just (gid, True) -> "   group: " ++ gid; _ -> "" }
