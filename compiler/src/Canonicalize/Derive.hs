{-# OPTIONS_GHC -Wall #-}
-- Ficcus (A4a): the `derive` lines of a module (docs/A4-DERIVE-DESIGN.md; AST.Derive has the names).
--
-- Two steps around Canonicalize.Module.canonicalize:
--
--   prepare (on the source module, before anything else):  the `derive` line values come out; the checks that need
--     only the source run (unknown member, a member listed twice, two lines, DERIVE AND DEFINE, DERIVE SHADOWED,
--     DERIVE ON NON-ENUMERATION, `map` without a parameter); every listed member becomes an ordinary member
--     `T$$m` of the module with a synthesized signature (and one constraint `a has m` for each parameter of the type
--     that occurs in a field), so that the environment, the siblings of the `where` block (A1b), the constrained
--     schemes (A2), the solver's table (A3), the interface and G70 visibility treat it as a written member.
--   finish (on the canonical module):  CANNOT DERIVE (a part of the type without the member, a type used inside
--     itself at other arguments); the body of each derived member becomes the stub `Elm.Kernel.FicDerive.T.m`, which
--     the type checker takes at any type and the C generator refuses (A4a has no bodies); one marker definition per
--     type (`$derived$T$m1,m2`) is added, which Compile keeps out of the interface and the JavaScript output refuses.
--
-- A module without a `derive` line is returned unchanged by both steps.
module Canonicalize.Derive
  ( Entry
  , prepare
  , finish
  )
  where


import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing, mapMaybe, listToMaybe)

import qualified AST.Canonical as Can
import qualified AST.Constraints as Constraints
import qualified AST.Derive as Derive
import qualified AST.Members as Members
import qualified AST.Prim.Module as Module
import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeName as T
import qualified AST.Prim.TypeVar as TV
import qualified AST.Source as Src
import qualified AST.Utils.Type as Type
import qualified Elm.Interface as I
import qualified Elm.ModuleName as ModuleName
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Canonicalize as Error
import qualified Reporting.Error.Derive as DE
import qualified Reporting.Result as Result
import qualified String as S
import qualified Type.Members as TMembers



type Result i w a =
  Result.Result i w Error.Error a


throw :: DE.Error -> Result i w a
throw err =
  Result.throw (Error.Derive err)


-- | one derived member: the type, the member, the region of the member in the `derive` line
data Entry =
  Entry
    { _type :: String
    , _member :: String
    , _region :: A.Region
    }



-- PREPARE


prepare :: Src.Module -> Result i w (Src.Module, [Entry])
prepare modul@(Src.Module name exports docs imports values unions aliases binops effects) =
  case mapMaybe Derive.lineOf values of
    [] ->
      Result.ok (modul, [])

    lines_ ->
      do  let others = filter (isNothing . Derive.lineOf) values
          let unionMap = Map.fromList [ (T.nameToChars n, (map A.toValue vars, variants)) | A.At _ (Src.Union (A.At _ n) vars variants) <- unions ]
          entries <- checkLines lines_
          mapM_ (checkDefined others) entries
          mapM_ (checkShadowed (Module.toChars (Src.getName modul)) others) entries
          mapM_ (checkUnion unionMap) entries
          let stubs = map (stub unionMap) entries
          Result.ok (Src.Module name exports docs imports (others ++ stubs) unions aliases binops effects, entries)


-- unknown members, a member listed twice, two lines for one type
checkLines :: [Derive.Line] -> Result i w [Entry]
checkLines lines_ =
  go Map.empty [] lines_
  where
    go seenLines acc ls =
      case ls of
        [] ->
          Result.ok (reverse acc)

        Derive.Line region tipe members : rest ->
          case Map.lookup tipe seenLines of
            Just first -> throw (DE.TwoLines first region tipe)
            Nothing ->
              do  es <- goMembers tipe [] members
                  go (Map.insert tipe region seenLines) (reverse es ++ acc) rest

    goMembers tipe acc members =
      case members of
        [] ->
          Result.ok (reverse acc)

        A.At region member : rest ->
          let chars = N.toChars member in
          if chars `notElem` Derive.known then
            throw (DE.Unknown region tipe chars)
          else
            case [ r | Entry _ m r <- acc, m == chars ] of
              first : _ -> throw (DE.Twice first region tipe chars)
              [] -> goMembers tipe (Entry tipe chars region : acc) rest


-- DERIVE AND DEFINE: the member is also written in the `where` block
checkDefined :: [A.Located Src.Value] -> Entry -> Result i w ()
checkDefined values (Entry tipe member region) =
  let mangled = Members.mangle (tname tipe) (fromChars member) in
  case [ r | A.At _ (Src.Value (A.At r n) _ _ _) <- values, n == mangled ] of
    written : _ -> throw (DE.AndDefine region written tipe member)
    [] -> Result.ok ()


-- DERIVE SHADOWED: the module defines a top level function of the member's name (A4a reading of section 4 of the note:
-- any top level definition of that name, exposed or not; see the A4a report)
checkShadowed :: String -> [A.Located Src.Value] -> Entry -> Result i w ()
checkShadowed modul values (Entry tipe member region) =
  case [ r | A.At _ (Src.Value (A.At r n) _ _ _) <- values, N.toChars n == member ] of
    defined : _ -> throw (DE.Shadowed region defined modul tipe member)
    [] -> Result.ok ()


type UnionMap =
  Map.Map String ([T.Var], [(A.Located N.Name, [Src.Type])])


-- DERIVE ON NON-ENUMERATION; `map` needs a type parameter
checkUnion :: UnionMap -> Entry -> Result i w ()
checkUnion unionMap (Entry tipe member region) =
  case Map.lookup tipe unionMap of
    Nothing ->
      Result.ok ()

    Just (vars, variants)
      | Derive.isEnumMember member
      , A.At _ ctor : _ <- [ c | (c, _ : _) <- variants ] ->
          throw (DE.NonEnumeration region tipe member (N.toChars ctor))

      | member == "map" && null vars ->
          throw (DE.Cannot region tipe member DE.NoParameter)

      | otherwise ->
          Result.ok ()



-- THE SIGNATURES


-- | the member `T$$m` with its signature and a placeholder body (finish replaces it by the stub)
stub :: UnionMap -> Entry -> A.Located Src.Value
stub unionMap (Entry tipe member r) =
  A.At r (Src.Value (A.At r (Members.mangle (tname tipe) (fromChars member))) (map hiddenPattern constrained) (A.At r Src.Unit) (Just signature))
  where
    (vars, variants) = Map.findWithDefault ([], []) tipe unionMap
    at = A.At r
    self = at (Src.TType r (tname tipe) [ at (Src.TVar v) | v <- vars ])
    qual modul n args = at (Src.TTypeQual r (Module.toPrefix (Module.fromString (S.fromChars modul))) (tname n) args)
    fn a b = at (Src.TLambda a b)

    used = concatMap (\(_, args) -> concatMap srcVars args) variants
    constrained =
      if member `elem` ["compare", "hash", "toString", "fromString", "encode", "decoder"]
        then [ v | v <- vars, v `elem` used ]
        else []

    shape s =
      case member of
        "compare" -> fn s (fn s (qual "Basics" "Order" []))
        "hash" -> fn s (qual "Basics" "Int" [])
        "toString" -> fn s (qual "String" "String" [])
        "fromString" -> fn (qual "String" "String" []) (qual "Maybe" "Maybe" [s])
        "encode" -> fn s (qual "Json.Encode" "Value" [])
        "decoder" -> qual "Json.Decode" "Decoder" [s]
        "succ" -> fn s (qual "Maybe" "Maybe" [s])
        "pred" -> fn s (qual "Maybe" "Maybe" [s])
        "enumerate" -> qual "List" "List" [s]
        _ -> s     -- minValue, maxValue

    real =
      case (member, reverse vars) of
        ("map", lastVar : _) ->
          let
            b = head [ v | v <- map (TV.varFromString . S.fromChars) ("b" : [ "b" ++ show i | i <- [(1 :: Int) ..] ]), v `notElem` vars ]
            other = at (Src.TType r (tname tipe) [ at (Src.TVar (if v == lastVar then b else v)) | v <- vars ])
          in
          fn (fn (at (Src.TVar lastVar)) (at (Src.TVar b))) (fn self other)
        _ ->
          shape self

    signature =
      foldr (\v acc -> fn (shape (at (Src.TVar v))) acc) real constrained

    hiddenPattern v =
      at (Src.PAlias (at (Src.PVar (Constraints.marker (TV.varToChars v) (fromChars member)))) (at (fromChars (member ++ "$" ++ TV.varToChars v))))


srcVars :: Src.Type -> [T.Var]
srcVars (A.At _ t) =
  case t of
    Src.TLambda a b -> srcVars a ++ srcVars b
    Src.TVar v -> [v]
    Src.TType _ _ args -> concatMap srcVars args
    Src.TTypeQual _ _ _ args -> concatMap srcVars args
    Src.TRecord fields ext -> concatMap (srcVars . snd) fields ++ maybe [] (\(A.At _ v) -> [v]) ext
    Src.TUnit -> []
    Src.TTuple a b cs -> concatMap srcVars (a : b : cs)



-- FINISH


finish :: Map.Map Module.Name I.Interface -> [Entry] -> Can.Module -> Result i w Can.Module
finish ifaces entries modul@(Can.Module home exports docs decls unions aliases binops effects) =
  case entries of
    [] ->
      Result.ok modul

    _ ->
      do  let table = TMembers.toTable ifaces modul
          mapM_ (checkParts home table unions) entries
          let stubs = Map.fromList [ (Members.mangle (tname t) (fromChars m), Derive.stubName t m) | Entry t m _ <- entries ]
          let markers = [ marker t (map _member es) | es@(Entry t _ _ : _) <- List.groupBy (\a b -> _type a == _type b) entries ]
          Result.ok (Can.Module home exports docs (foldr Can.Declare (stubBodies stubs decls) markers) unions aliases binops effects)


marker :: String -> [String] -> Can.Def
marker tipe members =
  Can.Def (A.At A.zero (Derive.marker tipe members)) [] (A.At A.zero Can.Unit)


stubBodies :: Map.Map N.Name N.Name -> Can.Decls -> Can.Decls
stubBodies stubs decls =
  case decls of
    Can.Declare d rest -> Can.Declare (def d) (stubBodies stubs rest)
    Can.DeclareRec d ds rest -> Can.DeclareRec (def d) (map def ds) (stubBodies stubs rest)
    Can.SaveTheEnvironment -> Can.SaveTheEnvironment
  where
    def d =
      case d of
        Can.TypedDef name@(A.At r n) freeVars args (A.At _ _) result
          | Just kname <- Map.lookup n stubs ->
              Can.TypedDef name freeVars args (A.At r (Can.VarKernel kernel kname)) result
        _ ->
          d

    kernel =
      Module.getKernel (Module.fromString (S.fromChars ("Elm.Kernel." ++ Derive.kernelHome)))



-- CANNOT DERIVE


checkParts :: ModuleName.Canonical -> TMembers.Table -> Map.Map T.Name Can.Union -> Entry -> Result i w ()
checkParts home table unions (Entry tipe member region) =
  case Map.lookup (tname tipe) unions of
    Nothing ->
      Result.ok ()

    Just (Can.Union vars ctors _ _) ->
      let
        parts = [ (ctorPath name (length args) i, arg) | Can.Ctor name _ _ args <- ctors, (i, arg) <- zip [1 :: Int ..] args ]
        regular = listToMaybe (concatMap (nonRegular home (tname tipe) vars . snd) parts)
        needs = member `elem` ["compare", "hash", "toString", "fromString", "encode", "decoder"]
        missing = if needs then listToMaybe (mapMaybe (\(path, t) -> lacks table member path t) parts) else Nothing
      in
      case (regular, missing) of
        (Just use, _) -> throw (DE.Cannot region tipe member (DE.NonRegular use))
        (_, Just reason) -> throw (DE.Cannot region tipe member reason)
        _ -> Result.ok ()


ctorPath :: N.Name -> Int -> Int -> String
ctorPath ctor arity i =
  if arity == 1 then N.toChars ctor else N.toChars ctor ++ " > argument " ++ show i


-- | the first part of the type that does not have the member
lacks :: TMembers.Table -> String -> String -> Can.Type -> Maybe DE.Reason
lacks table member path tipe =
  case tipe of
    Can.TVar _ ->
      Nothing     -- the member gets the constraint `a has m`

    Can.TLambda _ _ ->
      Just (DE.Lacks path (render tipe) Nothing)

    Can.TUnit ->
      Nothing

    Can.TPair a b ->
      firstOf [ (path ++ " > element 1", a), (path ++ " > element 2", b) ]

    Can.TTriple a b c ->
      firstOf [ (path ++ " > element 1", a), (path ++ " > element 2", b), (path ++ " > element 3", c) ]

    Can.TRecord fields _ ->
      firstOf [ (path ++ " > " ++ N.toChars f, t) | (f, Can.FieldType _ t) <- Map.toAscList fields ]

    Can.TAlias _ _ args aliasType ->
      lacks table member path (Type.dealias args aliasType)

    Can.TType home name args ->
      let tid = Members.typeId home name in
      case builtin tid of
        Just (Leaf members)
          | member `elem` members -> Nothing
          | otherwise -> Just (DE.Lacks path (render tipe) Nothing)

        Just (Container labels)
          | tid == vectorId && member == "compare" ->
              Just (DE.NotYet path (render tipe) "the order of a `Vector` comes with the Vector parity work")
          | otherwise ->
              firstOf [ (path ++ " > " ++ label, t) | (label, t) <- zip labels args ]

        Nothing ->
          case Map.lookup tid table >>= Map.lookup (fromChars member) of
            Nothing ->
              Just (DE.Lacks path (render tipe) (Just (T.nameToChars name)))

            Just maybeAnnotation ->
              -- a member with constraints needs the member at the arguments too (all of them: A4a does not tell
              -- which argument a constraint is about)
              if maybe False isConstrained maybeAnnotation
                then firstOf [ (path ++ " > " ++ T.nameToChars name ++ " argument " ++ show i, t) | (i, t) <- zip [1 :: Int ..] args ]
                else Nothing
  where
    firstOf = listToMaybe . mapMaybe (\(p, t) -> lacks table member p t)

    isConstrained (Can.Forall _ t) = Constraints.isWrapped t


data Builtin
  = Leaf [String]
  | Container [String]   -- the parts (by argument), which must have the member too


-- | the derivable members of the built-in types (the plan of A4b to A4d; the solver's table gets them with those slices)
builtin :: String -> Maybe Builtin
builtin tid =
  lookup tid $
    [ (core "Basics" "Int", all6), (core "Basics" "Float", all6), (core "Basics" "Bool", all6), (core "Basics" "Order", all6)
    , (core "String" "String", all6), (core "Char" "Char", all6)
    , ("elm/json:Json.Encode.Value", Leaf ["encode", "decoder"])
    , (core "List" "List", Container ["element"]), (core "Array" "Array", Container ["element"]), (core "Set" "Set", Container ["element"])
    , (core "Maybe" "Maybe", Container ["value"]), (core "Result" "Result", Container ["error", "value"])
    , (core "Dict" "Dict", Container ["key", "value"]), (vectorId, Container ["element"])
    ]
    ++ [ ("author/project:" ++ s ++ "." ++ s, all6) | s <- ["Int8", "Int16", "Int32", "Word8", "Word16", "Word32", "Word64", "Float32"] ]
  where
    core m n = "elm/core:" ++ m ++ "." ++ n
    all6 = Leaf ["compare", "hash", "toString", "fromString", "encode", "decoder"]


vectorId :: String
vectorId =
  "author/project:Vector.Vector"


-- | a use of the type inside itself at other arguments than its own parameters
nonRegular :: ModuleName.Canonical -> T.Name -> [T.Var] -> Can.Type -> [String]
nonRegular home tipe vars t =
  case t of
    Can.TType h n args
      | h == home && n == tipe && args /= map Can.TVar vars -> [render t]
      | otherwise -> concatMap again args
    Can.TLambda a b -> again a ++ again b
    Can.TRecord fields _ -> concatMap (\(Can.FieldType _ ft) -> again ft) (Map.elems fields)
    Can.TPair a b -> again a ++ again b
    Can.TTriple a b c -> again a ++ again b ++ again c
    Can.TAlias _ _ args aliasType -> again (Type.dealias args aliasType)
    Can.TVar _ -> []
    Can.TUnit -> []
  where
    again = nonRegular home tipe vars



-- RENDERING (for the messages: types as written, unqualified)


render :: Can.Type -> String
render t =
  case t of
    Can.TLambda a b -> renderArg True a ++ " -> " ++ render b
    Can.TType _ n args -> unwords (T.nameToChars n : map (renderArg False) args)
    Can.TAlias _ n args _ -> unwords (T.nameToChars n : map (renderArg False . snd) args)
    _ -> renderArg False t


renderArg :: Bool -> Can.Type -> String
renderArg inLambda t =
  case t of
    Can.TVar v -> TV.varToChars v
    Can.TUnit -> "()"
    Can.TPair a b -> "( " ++ render a ++ ", " ++ render b ++ " )"
    Can.TTriple a b c -> "( " ++ render a ++ ", " ++ render b ++ ", " ++ render c ++ " )"
    Can.TRecord fields ext ->
      "{ " ++ maybe "" (\v -> TV.varToChars v ++ " | ") ext
        ++ List.intercalate ", " [ N.toChars f ++ " : " ++ render ft | (f, Can.FieldType _ ft) <- Map.toAscList fields ] ++ " }"
    Can.TLambda _ _ -> "(" ++ render t ++ ")"
    Can.TType _ _ [] -> render t
    Can.TAlias _ _ [] _ -> render t
    _ -> if inLambda then render t else "(" ++ render t ++ ")"



-- HELPERS


fromChars :: String -> N.Name
fromChars =
  N.fromString . S.fromChars


tname :: String -> T.Name
tname =
  T.nameFromString . S.fromChars
