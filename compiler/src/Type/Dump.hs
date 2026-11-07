{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE MagicHash #-}
module Type.Dump
  ( render
  , Result(..)
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
import Control.Monad.State.Strict (State, execState, gets, modify')
import Data.Bits (shiftR, (.&.))
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word64)
import GHC.Word (Word64(..))

import qualified AST.Canonical as Can
import qualified AST.Prim.Name as N
import qualified AST.Prim.Operator as Op
import qualified AST.Prim.TypeName as T
import qualified Elm.ModuleName as ModuleName
import qualified Elm.Package as Pkg
import qualified AST.Prim.Module as Module
import qualified Reporting.Annotation as A
import Type.Readout
import Type.Recorder (Key(..), DefKey(..))
import qualified Type.Recorder as Recorder



-- RESULT


data Result =
  Result
    { _text :: [String]
    , _problems :: Int
    , _matched :: Int
    , _matchFailed :: Int
    , _defaulted :: Int
    , _eqUses :: Int          -- direct uses of ==, /=, compare
    , _eqFunUses :: [String]  -- those whose instance type contains a function
    }



-- STATE


data W =
  W
    { _out :: [String]                 -- reversed
    , _bad :: Int
    , _ok :: Int
    , _failed :: Int
    , _defaultedCount :: Int
    , _eqCount :: Int
    , _eqFuns :: [String]
    , _seen :: Set.Set Key
    , _display :: Map.Map String String
    , _usedNames :: Set.Set String
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
    , _owned :: Map.Map String String               -- scheme variable -> token naming its owner definition and index
    }



-- RENDER


render :: Can.Module -> Typed -> Result
render (Can.Module home _ _ decls _ _ _ _) typed =
  let
    topDefs = declsToDefs decls
    vals = Map.fromList [ (defName d, Left (defKeyOf d)) | d <- topDefs ]
    ctx = Ctx typed Set.empty vals 0 home (Set.fromList [ defKeyOf d | d <- topDefs ]) Map.empty
    start = W [] 0 0 0 0 0 [] Set.empty Map.empty Set.empty
    w = execState (walkModule ctx home topDefs) start
    unvisited = Map.size (_nodes typed) - Set.size (_seen w)
    extra =
      if unvisited /= 0
        then [ "!! " ++ show unvisited ++ " recorded node(s) were not visited by the dump walk" ]
        else []
  in
  Result
    { _text = reverse (_out w) ++ extra
    , _problems = _bad w + (if unvisited /= 0 then 1 else 0)
    , _matched = _ok w
    , _matchFailed = _failed w
    , _defaulted = _defaultedCount w
    , _eqUses = _eqCount w
    , _eqFunUses = reverse (_eqFuns w)
    }


walkModule :: Ctx -> ModuleName.Canonical -> [Can.Def] -> M ()
walkModule ctx home defs =
  do  emit (ctx { _depth = 0 }) ("module " ++ moduleChars home)
      forM_ defs $ \def ->
        do  modify' (\w -> w { _display = Map.empty, _usedNames = Set.empty })
            walkDef ctx def


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
  modify' (\w -> w { _out = (replicate (2 * _depth ctx) ' ' ++ line) : _out w })


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
                    ++ "   id: " ++ did ++ "   sig: " ++ sigText ++ "   kinds: " ++ kindsText scheme)
          let owned' = List.foldl' (\m (u, i) -> Map.insertWith (\_ old -> old) u (varToken did i) m) (_owned ctx) (canonVars scheme)
          let inner = ctx { _scope = Set.union (_scope ctx) (Set.fromList (map fst (tvars scheme))), _depth = _depth ctx + 1, _owned = owned' }
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
          do  let ctx1 = bindDefs ctx [def]
              walkDef ctx1 def
              walkExpr ctx1 body
        Can.LetRec defs body ->
          do  let ctx1 = bindDefs ctx defs
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


bindDefs :: Ctx -> [Can.Def] -> Ctx
bindDefs ctx defs =
  ctx { _vals = List.foldl' (\m d -> Map.insert (defName d) (Left (defKeyOf d)) m) (_vals ctx) defs }


nodeLine :: Ctx -> A.Region -> Can.Expr_ -> M ()
nodeLine ctx region e =
  do  let key = Recorder.exprKey region e
      modify' (\w -> w { _seen = Set.insert key (_seen w) })
      case Map.lookup key (_nodes (_typed ctx)) of
        Nothing ->
          problem ctx ("missing type for " ++ Recorder.exprKind e ++ " at " ++ regionText region)

        Just raw ->
          do  (shown, extra) <- typeText ctx raw
              inst <- instanceText ctx e raw
              emit ctx (regionText region ++ " " ++ Recorder.exprKind e ++ " :: " ++ shown ++ extra ++ calleeText ctx e ++ inst)



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
  let rows = rowVarNames scheme
      kindOf u = case [ k | (n, k) <- tvars scheme, n == u ] of { k : _ -> k; [] -> KAny }
  in List.intercalate "," [ "v" ++ show i ++ ":" ++ (if Set.member u rows then "row" else kindWord (kindOf u)) | (u, i) <- canonVars scheme ]


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
          sig <- sigOf ctx scheme
          entries <-
            mapM
              (\(u, i) ->
                  case Map.lookup u subst of
                    Nothing -> return Nothing
                    Just (TVar other _ _) | other == u -> return Nothing
                    Just value ->
                      do  shown <- withNames ownedNames (showType (applyDefault dead value))
                          return (Just ("v" ++ show i ++ " := " ++ shown)))
              (canonVars scheme)
          let present = [ x | Just x <- entries ]
          return (if null present then "" else "   sig#: " ++ sigHash sig ++ "   subst: " ++ List.intercalate ", " present)

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
    Can.VarForeign _ _ ann -> Just (annotation ann, raw)
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

    nodeType (A.At r x) = Map.lookup (Recorder.exprKey r x) (_nodes (_typed ctx))


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
