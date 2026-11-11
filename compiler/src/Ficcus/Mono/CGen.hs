{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE PatternGuards #-}
module Ficcus.Mono.CGen
  ( generate
  )
  where


-- Ficcus, stage (iii) slice 1b: Lower (minimal subset) and Generate.C in one step: a Mono program to a
-- C99 file (`elm make x.fic --output=x.c`).
--
--   * every clone is a C function (values: a global and an initialiser, run by `fic_init` in program order);
--   * lifted local functions get the variables they use from their owner as leading parameters;
--   * a self tail call is a loop (`for (;;) ... continue`), as Elm guarantees;
--   * expressions with statements (if, let, sequence) are emitted as statements into temporaries; arguments
--     that are not atoms are bound to temporaries in order, because C leaves the order of evaluation open
--     and Elm's is left to right;
--   * `Platform.worker`: `main` must be `Platform.worker { init = ... }`; C `main` runs `fic_init`, then
--     the init function, and ignores the result (commands are ignored, STAGE3-PLAN R9);
--   * without `--rc` there is no dup/drop (the output of the first slices, the oracle of stage iv). With it (gRc) the program
--     comes from Ficcus.Mono.Rc: `MDup`/`MDrop`/`MOwn` become the counts, every expression yields an owned value, and the
--     places where the generator itself makes or consumes values (objects, struct boxes, closures) follow the same convention.


import Control.Monad (foldM, forM, forM_, when)
import Control.Monad.State.Strict (State, execState, gets, modify')
import Data.Bits (shiftR, (.&.))
import Data.Char (isAlphaNum, ord)
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import Ficcus.Mono.CRuntime (closureRuntime, fdlibmRuntime, jsArrayRuntime, prelude, stringRuntime)
import Ficcus.Mono.Class
import Ficcus.Mono.Free (captures, refClass)
import Ficcus.Mono.Ir
import Ficcus.Mono.Layout
import Ficcus.Mono.Print (keyTextIx)
import Ficcus.Mono.Spec (classOfM)



-- STATE


data G =
  G
    { gOut :: [String]               -- reversed
    , gIndent :: Int
    , gTmp :: Int
    , gErrors :: [String]
    , gSelf :: Maybe CloneId         -- the clone being generated (for self tail calls)
    , gSelfParams :: [String]
    , gLooped :: Bool                -- a self tail call was emitted
    , gWhere :: String               -- the clone being generated, for messages
    , gHelpers :: Map.Map HKey String   -- generated helper functions (equality, comparison, list append, sorts) by what they do
    , gPending :: [(HKey, String)]   -- helpers registered and not yet written
    , gProtos :: [String]            -- their prototypes and the extra types they need (written at HELPER_MARK)
    , gExtraObjs :: Set.Set [Class]  -- object layouts used only by helpers
    , gExtraStructs :: Set.Set [Class]
    , gNullary :: Set.Set Int          -- tags whose static nullary object (fic_nulN) is used
    , gRc :: Bool                      -- the program has counts (--rc): the generated code owns, dups and drops (STAGE4-PLAN)
    , gStrings :: Map.Map String Int   -- the static string literals, by text
    }


type CG a = State G a


data Info =
  Info
    { iClones :: Map.Map CloneId MDef
    , iCaptured :: Map.Map CloneId [(String, Class)]
    , iUnions :: Map.Map String UnionShape
    , iObjs :: Set.Set [Class]       -- the object layouts and struct types the clones define
    , iStructs :: Set.Set [Class]
    }


emit :: String -> CG ()
emit l =
  modify' (\g -> g { gOut = (replicate (2 * gIndent g) ' ' ++ l) : gOut g })


indented :: CG a -> CG a
indented act =
  do  modify' (\g -> g { gIndent = gIndent g + 1 })
      r <- act
      modify' (\g -> g { gIndent = gIndent g - 1 })
      return r


failWith :: String -> CG String
failWith msg =
  do  w <- gets gWhere
      modify' (\g -> g { gErrors = (msg ++ (if null w then "" else " (in " ++ w ++ ")")) : gErrors g })
      return "0"


fresh :: String -> CG String
fresh base =
  do  n <- gets gTmp
      modify' (\g -> g { gTmp = n + 1 })
      return (base ++ show n)



-- ENTRY


-- | the C text of a program, or the messages
generate :: Bool -> MProgram -> Either [String] String
generate rcMode program =
  case mpMain program of
    Nothing -> Left [ "internal: no main" ]
    Just root ->
      let
        clones = mpClones program
        info = Info (Map.fromList [ (mdClone d, d) | d <- clones ]) (captures clones) (mpUnions program)
                    (Set.fromList (allObjects clones)) (Set.fromList (structsOf clones))
        g0 = G [] 0 0 [] Nothing [] False "" Map.empty [] [] Set.empty Set.empty Set.empty rcMode Map.empty
        final = execState (program' info root clones) g0
      in
      case reverse (gErrors final) of
        [] ->
          let extra = concatMap structDef (Set.toList (gExtraStructs final))
                      ++ map objectDef (Set.toList (gExtraObjs final)) ++ reverse (gProtos final)
                      ++ [ "static fic_hdr fic_nul" ++ show t ++ " = { FIC_IMMORTAL, " ++ show t ++ "u, 0, 0 };" | t <- Set.toList (gNullary final), t > 1 ]
                      ++ [ staticString str i | (str, i) <- Map.toList (gStrings final) ]
              body = unlines (concatMap (\l -> if l == helperMark then extra else if l == "  /* PK_RELEASE */" then [ "  fic_pk_release();" | pkUsed ] else [l]) (reverse (gOut final)))
              pkUsed = any ("fic_pk_" `List.isInfixOf`) (gOut final)
              -- the closure runtime (words, apply functions) only for programs that use closures, the sort runtime for sorts
          in Right ((if rcMode then "#define FIC_RC 1\n" else "") ++ prelude ++ "\n" ++ (if any (`List.isInfixOf` body) ["fic_word", "fic_ja_", "fic_us_", "fic_pk_"] then closureRuntime ++ "\n" else "")
                    ++ (if "fic_fd_" `List.isInfixOf` body then fdlibmRuntime ++ "\n" else "")
                    ++ (if "fic_ja_" `List.isInfixOf` body then jsArrayRuntime ++ "\n" else "")
                    ++ (if any (`List.isInfixOf` body) ["fic_us_", "fic_pk_"] then stringRuntime ++ "\n" else "")
                    ++ "\n" ++ body)
        errs -> Left errs


program' :: Info -> CloneId -> [MDef] -> CG ()
program' info root clones =
  do  emit "/* generated by the Ficcus compiler (stage iii, slice 3b): do not edit */"
      emit ""
      mapM_ emit (concatMap structDef (structsOf clones))
      mapM_ emit (map objectDef (allObjects clones))
      emit ""
      let funs = [ d | d <- clones, mdClone d /= root, isFunction d ]
      let values = [ d | d <- clones, mdClone d /= root, not (isFunction d) ]
      forM_ funs (\d -> emit (signature info d ++ ";"))
      forM_ values (\d -> emit ("static " ++ classType (mdResult d) ++ " " ++ globalName d ++ ";"))
      forM_ values (\d -> emit ("static " ++ classType (mdResult d) ++ " " ++ valueName d ++ "(void);"))
      emit ""
      emit helperMark
      closureSection info (closureClones info clones)
      forM_ funs (genFunction info)
      forM_ values (genValue info)
      genHelpers info
      emit "static void fic_init(void) {"
      indented (forM_ values (\d -> emit (globalName d ++ " = " ++ valueName d ++ "();")))
      emit "}"
      emit ""
      initFn <- workerInit info root
      emit "int main(void) {"
      indented $
        do  rcMode <- gets gRc
            emit "fic_init();"
            case initFn of
              Just d
                | rcMode && refClass (mdResult d) ->
                    do  emit (classType (mdResult d) ++ " fic_res = " ++ functionName d ++ "(0);")
                        mapM_ (\p -> emit ("fic_drop(" ++ p ++ ");")) (refPaths (mdResult d) "fic_res")
                | otherwise -> emit ("(void)" ++ functionName d ++ "(0);")
              Nothing -> return ()
            -- the global values hold one count each for ever: they are dropped only for the checks of the test builds
            when rcMode $
              do  emit "#if defined(FIC_DROP_ALL) || defined(FIC_STATS)"
                  forM_ values (\d -> mapM_ (\p -> emit ("fic_drop(" ++ p ++ ");")) (refPaths (mdResult d) (globalName d)))
                  emit "#endif"
            when rcMode (emit "/* PK_RELEASE */")
            emit "#if defined(FIC_DROP_ALL) || defined(FIC_STATS)"
            emit "if (fic_shutdown() != 0) return 3;"
            emit "#endif"
            emit "return 0;"
      emit "}"


isFunction :: MDef -> Bool
isFunction d = mdKind d == Function


-- main = Platform.worker { init = ... }
workerInit :: Info -> CloneId -> CG (Maybe MDef)
workerInit info root =
  case Map.lookup root (iClones info) >>= mdBody of
    Just (MExpr _ (MCall (MExpr _ (MKernel "elm/core:Platform.worker" _)) [MExpr _ (MGlobal i)])) ->
      return (Map.lookup i (iClones info))
    _ ->
      do  _ <- failWith "main is not `Platform.worker { init = \\flags -> ... }` (the only program shape supported in slice 1)"
          return Nothing



-- NAMES AND TYPES


sanitize :: String -> String
sanitize s =
  let base = reverse (takeWhile (\c -> c /= '.' && c /= ':') (reverse (takeWhile (/= '@') s)))
  in map (\c -> if isAlphaNum c then c else '_') (if null base then "x" else base)


functionName :: MDef -> String
functionName d = let CloneId n = mdClone d in "f" ++ show n ++ "_" ++ sanitize (mdName d)


globalName :: MDef -> String
globalName d = let CloneId n = mdClone d in "g" ++ show n ++ "_" ++ sanitize (mdName d)


valueName :: MDef -> String
valueName d = let CloneId n = mdClone d in "val" ++ show n ++ "_" ++ sanitize (mdName d)


localName :: String -> String
localName n = "v_" ++ map (\c -> if isAlphaNum c || c == '_' then c else '_') n


-- struct types used by the program, inner ones first
structsOf :: [MDef] -> [[Class]]
structsOf clones =
  List.nub (concatMap fromClass (concatMap classesOfDef clones))
  where
    fromClass c =
      case c of
        CStruct fs -> concatMap fromClass fs ++ [fs]
        _ -> []


classesOfDef :: MDef -> [Class]
classesOfDef d =
  mdResult d : map snd (mdParams d) ++ maybe [] classesOfExpr (mdBody d)


classesOfExpr :: MExpr -> [Class]
classesOfExpr e =
  mRep e : concatMap classesOfExpr (children e) ++
  (case mNode e of
     MCase _ bs -> concatMap (classesOfPat . fst) bs
     _ -> [])


classesOfPat :: MPat -> [Class]
classesOfPat (MPat c n) =
  c : (case n of
         PCtor _ _ ps -> concatMap classesOfPat ps
         PTuple ps -> concatMap classesOfPat ps
         PCons a b -> classesOfPat a ++ classesOfPat b
         PAlias p _ -> classesOfPat p
         PRecord fs -> [ fc | (_, _, fc) <- fs ]
         _ -> [])


-- the object layouts of the program: those of constructors and list cells, and one box per struct class (a struct held
-- where a single word is needed: a closure word, an array element, a variable of unconstrained type)
allObjects :: [MDef] -> [[Class]]
allObjects clones = List.nub (objectsOf clones ++ [ [CStruct fs] | fs <- structsOf clones ])


-- the layouts of the heap objects of constructors and list cells: a header and the fields (STAGE3-PLAN: a
-- struct field of a constructor is boxed, so a field class is never a struct)
objectsOf :: [MDef] -> [[Class]]
objectsOf clones =
  List.nub (concatMap (\d -> maybe [] objectsOfExpr (mdBody d)) clones)


objectsOfExpr :: MExpr -> [[Class]]
objectsOfExpr e =
  concatMap objectsOfExpr (children e) ++
  (case mNode e of
     MCall (MExpr _ (MCtor _ _ (Key parts))) _ -> [[ c | ByClass c <- parts ]]
     MCall (MExpr _ (MKernel "elm/core:List.cons" (Key [ByClass c]))) _ -> [[c, CRef]]
     MList xs -> [] : [ [boxedClass (mRep x), CRef] | x <- take 1 xs ]
     MCtor _ _ (Key []) -> [[]]
     MCase _ bs -> concatMap (objectsOfPat . fst) bs
     _ -> [])


objectsOfPat :: MPat -> [[Class]]
objectsOfPat (MPat _ n) =
  case n of
    PCtor _ _ ps -> [ map (boxedClass . mpRep) ps | not (null ps) ] ++ concatMap objectsOfPat ps
    PTuple ps -> concatMap objectsOfPat ps
    PCons a b -> [boxedClass (mpRep a), CRef] : objectsOfPat a ++ objectsOfPat b
    PAlias p _ -> objectsOfPat p
    _ -> []


boxedClass :: Class -> Class
boxedClass c = case c of { CStruct _ -> CRef; _ -> c }


structDef :: [Class] -> [String]
structDef fs =
  [ "typedef struct { " ++ concat [ classType c ++ " f" ++ show i ++ "; " | (i, c) <- zip [0 :: Int ..] fs ] ++ "} " ++ classType (CStruct fs) ++ ";" ]



-- FUNCTIONS


signature :: Info -> MDef -> String
signature info d =
  let caps = Map.findWithDefault [] (mdClone d) (iCaptured info)
      params = [ classType c ++ " " ++ localName n | (n, c) <- caps ++ mdParams d ]
  in "static " ++ classType (mdResult d) ++ " " ++ functionName d ++ "(" ++ (if null params then "void" else List.intercalate ", " params) ++ ")"


-- | the comment above each clone: its number, definition and key (STAGE3-PLAN Q1)
cloneComment :: MDef -> String
cloneComment d =
  let CloneId n = mdClone d
  in "/* c" ++ show n ++ " " ++ safe (mdName d) ++ "   key: " ++ safe (keyTextIx (mdVars d) (mdKey d))
     ++ maybe "" (\(CloneId o) -> "   lifted-from: c" ++ show o) (mdLifted d)
     ++ (case [ pn | ((pn, _), Borrowed) <- zip (mdParams d) (paramOwns d) ] of { [] -> ""; ns -> "   borrowed: " ++ unwords (map safe ns) }) ++ " */"
  where
    safe = concatMap (\c -> if c == '*' then "_" else [c])


genFunction :: Info -> MDef -> CG ()
genFunction info d =
  do  modify' (\g -> g { gWhere = functionName d })
      emit (cloneComment d)
      emit (signature info d ++ " {")
      modify' (\g -> g { gSelf = Just (mdClone d), gSelfParams = map fst (mdParams d), gLooped = False })
      -- the body is generated first to know whether a loop is needed
      saved <- gets gOut
      savedIndent <- gets gIndent
      modify' (\g -> g { gOut = [], gIndent = savedIndent + 1 })
      let usedNames = maybe Set.empty usedLocals (mdBody d)
      forM_ (mdParams d) $ \(n, _) ->
        when (not (Set.member n usedNames)) (emit ("(void)" ++ localName n ++ ";"))
      case mdBody d of
        Just b -> genRet info b
        Nothing -> return ()
      body <- gets gOut
      looped <- gets gLooped
      modify' (\g -> g { gOut = saved, gIndent = savedIndent, gSelf = Nothing })
      if looped
        then
          do  emit "  for (;;) {"
              modify' (\g -> g { gOut = map ("  " ++) body ++ gOut g })
              emit "  }"
        else modify' (\g -> g { gOut = body ++ gOut g })
      emit "}"
      emit ""


genValue :: Info -> MDef -> CG ()
genValue info d =
  do  modify' (\g -> g { gWhere = valueName d })
      emit (cloneComment d)
      emit ("static " ++ classType (mdResult d) ++ " " ++ valueName d ++ "(void) {")
      modify' (\g -> g { gSelf = Nothing, gSelfParams = [], gLooped = False })
      indented (maybe (return ()) (genRet info) (mdBody d))
      emit "}"
      emit ""


-- statements that return the value of an expression; a self tail call becomes a jump to the loop start
genRet :: Info -> MExpr -> CG ()
genRet info e =
  case mNode e of
    MIf bs final -> genIfRet bs final
    MCase scrut bs -> genCase info (genRet info) scrut bs
    MDup vs b -> do { dupVars vs; genRet info b }
    MDrop vs b -> do { dropVars vs; genRet info b }
    MUnpack s c bs b -> do { unpackDrops s c bs; genRet info b }
    MLetVal n v b ->
      do  v' <- genExpr info v
          emit (classType (mRep v) ++ " " ++ localName n ++ " = " ++ v' ++ ";")
          when (take 3 n == "_pv") (emit ("(void)" ++ localName n ++ ";"))
          genRet info b
    MSeq a b ->
      do  a' <- genExpr info a
          emit ("(void)(" ++ a' ++ ");")
          genRet info b
    MCall (MExpr _ (MGlobal c)) args ->
      do  self <- gets gSelf
          params <- gets gSelfParams
          if Just c == self && length args == length params
            then
              do  let pcls = maybe [] (map snd . mdParams) (Map.lookup c (iClones info))
                  let targets = pcls ++ map mRep (drop (length pcls) args)
              -- evaluate all arguments, in order, into temporaries before assigning any parameter (a value that is an expression
              -- must be computed now: a later argument may drop what it uses)
                  temps <- forM (zip3 args targets params) $ \(a, pc, p) ->
                    do  v <- genExpr info a >>= adaptOwn (mRep a) pc
                        t <- fresh "tail"
                        emit (classType pc ++ " " ++ t ++ " = " ++ v ++ ";")
                        return (p, t)
                  forM_ temps (\(p, t) -> emit (localName p ++ " = " ++ t ++ ";"))
                  emit "continue;"
                  modify' (\g -> g { gLooped = True })
            else plain
    _ -> plain
  where
    plain =
      do  v <- genExpr info e
          emit ("return " ++ v ++ ";")
    genIfRet [] final = genRet info final
    genIfRet ((c, b) : rest) final =
      do  c' <- genExpr info c
          emit ("if (" ++ condText c' ++ ") {")
          indented (genRet info b)
          emit "} else {"
          indented (genIfRet rest final)
          emit "}"



-- EXPRESSIONS


atom :: MExpr -> Bool
atom e =
  case mNode e of
    MLit _ -> True
    MLocal _ -> True
    MKernel _ _ -> True
    _ -> False


-- a C expression for the value; statements it needs are emitted first
genExpr :: Info -> MExpr -> CG String
genExpr info e =
  case mNode e of
    MLit l -> literal (mRep e) l
    MLocal n -> return (localName n)
    MDup vs b -> do { dupVars vs; genExpr info b }
    MDrop vs b -> do { dropVars vs; genExpr info b }
    MUnpack s c bs b -> do { unpackDrops s c bs; genExpr info b }
    MOwn b ->
      do  v <- genExpr info b
          t <- variable (mRep b) v
          dupVars' (mRep b) t
          return t
    MGlobal c ->
      case Map.lookup c (iClones info) of
        Just d | not (isFunction d) -> adapt (mdResult d) (mRep e) (globalName d)
        Just d -> closureValue info d
        Nothing -> failWith "internal: a reference to an unknown clone"
    MKernel name key -> kernelValue name key
    MCall (MExpr _ (MKernel name key)) args -> kernelCall info (mRep e) name key args
    MCall (MExpr _ (MGlobal c)) args | Just d <- Map.lookup c (iClones info), isFunction d, length args == length (mdParams d) ->
      do  vals <- atomsTo info (zip args (map snd (mdParams d)))
          let caps = [ localName n | (n, _) <- Map.findWithDefault [] c (iCaptured info) ]
          adaptOwn (mdResult d) (mRep e) (functionName d ++ "(" ++ List.intercalate ", " (caps ++ vals) ++ ")")
    MCall (MExpr _ (MCtor _ tag (Key parts))) args ->
      do  let cs = [ c | ByClass c <- parts ]
          vals <- atomsTo info (zip args cs)
          allocObj cs tag vals
    MCall h args -> unknownCall info e h args
    MCtor _ tag (Key []) ->
      if mRep e == CEnum then return (show tag) else nullary tag
    MList xs ->
      do  let cs = boxedClass . mRep
          vals <- atomsTo info [ (x, cs x) | x <- xs ]
          nil <- nullaryOwned 0
          foldM (\acc (x, v) -> allocObj [cs x, CRef] 1 [v, acc]) nil (reverse (zip xs vals))
    MCase scrut bs ->
      do  t <- fresh "t"
          emit (classType (mRep e) ++ " " ++ t ++ ";")
          genCase info (\b -> genExpr info b >>= \v -> emit (t ++ " = " ++ v ++ ";")) scrut bs
          return t
    MAccess r _ i ->
      case mRep r of
        CStruct fs ->
          do  r' <- genExpr info r
              adapt (fs !! i) (mRep e) ("(" ++ r' ++ ").f" ++ show i)
        _ -> failWith "internal: a field access on a value that is not a struct"
    MIf bs final ->
      do  t <- fresh "t"
          emit (classType (mRep e) ++ " " ++ t ++ ";")
          ifChain t bs final
          return t
    MLetVal n v b ->
      do  v' <- genExpr info v
          emit (classType (mRep v) ++ " " ++ localName n ++ " = " ++ v' ++ ";")
          when (take 3 n == "_pv") (emit ("(void)" ++ localName n ++ ";"))      -- a hoisted polymorphic value may be unused
          genExpr info b
    MSeq a b ->
      do  a' <- genExpr info a
          emit ("(void)(" ++ a' ++ ");")
          genExpr info b
    MTuple xs ->
      do  vals <- atomsTo info (zip xs (structFields (mRep e) xs))
          return ("(" ++ classType (mRep e) ++ "){ " ++ List.intercalate ", " vals ++ " }")
    MRecord fs ->
      do  vals <- atomsTo info (zip (map snd fs) (structFields (mRep e) (map snd fs)))
          return ("(" ++ classType (mRep e) ++ "){ " ++ List.intercalate ", " vals ++ " }")
    _ -> failWith "this expression form is not supported by the C generator yet"
  where
    ifChain t [] final =
      do  v <- genExpr info final
          emit (t ++ " = " ++ v ++ ";")
    ifChain t ((c, b) : rest) final =
      do  c' <- genExpr info c
          emit ("if (" ++ condText c' ++ ") {")
          indented (genExpr info b >>= \v -> emit (t ++ " = " ++ v ++ ";"))
          emit "} else {"
          indented (ifChain t rest final)
          emit "}"


-- CLOSURES (runtime/fic_closure.h)
--
-- A function clone used as a value (`MGlobal c` of a function, not at the head of a call) becomes a closure
-- { header, code, captured values } whose code is a static { entry, arity }. The entry function takes and
-- returns fic_word (the uniform ABI): a struct is passed boxed, every other class in its own member of the union,
-- so the code of a closure does not depend on the key of the caller. A call whose callee is not a known clone is
-- `fic_apN(f, mask, words)`, which checks the arity of f at run time (partial application, over-application).


maxArity :: Int
maxArity = 9


-- the function clones that are used as values, in order of first use
closureClones :: Info -> [MDef] -> [MDef]
closureClones info clones =
  List.nubBy (\a b -> mdClone a == mdClone b)
    [ d | c <- concatMap (maybe [] closureRefs . mdBody) clones, Just d <- [Map.lookup c (iClones info)], isFunction d ]


closureRefs :: MExpr -> [CloneId]
closureRefs e =
  case mNode e of
    MCall (MExpr _ (MGlobal _)) args -> concatMap closureRefs args
    MCall (MExpr _ (MKernel "elm/core:Platform.worker" _)) _ -> []
    MGlobal c -> [c]
    _ -> concatMap closureRefs (children e)


-- the class a value has in a closure's words (the ABI class): a struct is boxed
abiClass :: Class -> Class
abiClass = boxedClass


wordSel :: Class -> String
wordSel c =
  case abiClass c of
    CI64 -> ".i"
    CF64 -> ".d"
    CU32 -> ".c"
    CEnum -> ".b"
    CUnit -> ".b"
    _ -> ".p"


wordMk :: Class -> String -> String
wordMk c v =
  case abiClass c of
    CI64 -> "fic_w_i(" ++ v ++ ")"
    CF64 -> "fic_w_d(" ++ v ++ ")"
    CU32 -> "fic_w_c(" ++ v ++ ")"
    CEnum -> "fic_w_b(" ++ v ++ ")"
    CUnit -> "fic_w_b(" ++ v ++ ")"
    _ -> "fic_w_p(" ++ v ++ ")"


cloName, codeName, stubName :: MDef -> String
cloName d = let CloneId n = mdClone d in "clo" ++ show n
codeName d = let CloneId n = mdClone d in "code" ++ show n
stubName d = let CloneId n = mdClone d in "entry" ++ show n


-- the captured variables as the fields of the closure object: (name, class of the variable, class of the field); a struct
-- is flattened into the object (Layout: references first, then scalars)
capLayout :: [(String, Class)] -> [(String, Class, Class)]
capLayout caps = [ (n, c, c) | (n, c) <- caps ]


capType :: [(String, Class, Class)] -> String
capType layout = "fic_k_" ++ concatMap (\(_, _, fc) -> classTag fc) layout


capLayouts :: Info -> [MDef] -> [[(String, Class, Class)]]
capLayouts info ds =
  List.nubBy (\a b -> capType a == capType b) [ l | d <- ds, let l = capLayout (Map.findWithDefault [] (mdClone d) (iCaptured info)), not (null l) ]


-- the stubs, code descriptors and static closures, after the prototypes of the clones they call
closureSection :: Info -> [MDef] -> CG ()
closureSection info ds =
  do  forM_ (capLayouts info ds) $ \l ->
        emit (objectDefWith "const fic_code *code; " (capType l) [ fc | (_, _, fc) <- l ])
      forM_ ds $ \d ->
        do  modify' (\g -> g { gWhere = functionName d })
            let caps = Map.findWithDefault [] (mdClone d) (iCaptured info)
            let layout = capLayout caps
            let ps = mdParams d
            when (null ps || length ps > maxArity) $
              void' (failWith ("a closure of " ++ show (length ps) ++ " parameters (the closure runtime has arities 1 to " ++ show maxArity ++ ")"))
            emit (cloneComment d)
            emit ("static fic_word " ++ stubName d ++ "(fic_ref self" ++ concat [ ", fic_word a" ++ show i | (i, _) <- zip [0 :: Int ..] ps ] ++ ") {")
            indented $
              do  emit "(void)self;"
                  capVals <-
                    if null layout then return []
                    else
                      do  emit (capType layout ++ " *s = (" ++ capType layout ++ " *)self;")
                          forM caps $ \(n, _) ->
                            case [ i | (i, (m, _, _)) <- zip [0 :: Int ..] layout, m == n ] of
                              i : _ -> return (fieldRead classType [ fc | (_, _, fc) <- layout ] i "s")
                              [] -> failWith "internal: a captured variable is not in the closure layout"
                  -- the entry takes every argument owned: an argument the function only borrows is dropped after the call (S3, f_entry)
                  let owns = zip3 [0 :: Int ..] ps (paramOwns d)
                  vals <- forM owns (\(i, (_, pc), o) ->
                            let w = "a" ++ show i ++ wordSel pc
                            in if o == Borrowed then adapt (abiClass pc) pc w else adaptOwn (abiClass pc) pc w)
                  let drops = [ "fic_drop(a" ++ show i ++ ".p);" | (i, (_, pc), o) <- owns, o == Borrowed, abiClass pc == CRef ]
                  let call = functionName d ++ "(" ++ List.intercalate ", " (capVals ++ vals) ++ ")"
                  res <-
                    if null drops then return call
                    else do { rv <- fresh "rv"; emit (classType (mdResult d) ++ " " ++ rv ++ " = " ++ call ++ ";"); mapM_ emit drops; return rv }
                  r <- adaptOwn (mdResult d) (abiClass (mdResult d)) res
                  emit ("return " ++ wordMk (mdResult d) r ++ ";")
            emit "}"
            emit ("static const fic_code " ++ codeName d ++ " = { (void (*)(void))" ++ stubName d ++ ", " ++ show (length ps) ++ "u };")
            when (null layout) $
              emit ("static fic_clo " ++ cloName d ++ " = { { FIC_IMMORTAL, FIC_TAG_CLOSURE, 0, 0 }, &" ++ codeName d ++ " };")
            emit ""
  where void' act = act >> return ()


-- a closure value of a function clone: the static object, or a new object holding the captured values
closureValue :: Info -> MDef -> CG String
closureValue info d =
  let layout = capLayout (Map.findWithDefault [] (mdClone d) (iCaptured info))
  in
  if null layout
    then return ("(&" ++ cloName d ++ ".h)")
    else
      do  o <- fresh "k"
          let t = capType layout
          let fcs = [ fc | (_, _, fc) <- layout ]
          emit (t ++ " *" ++ o ++ " = (" ++ t ++ " *)fic_alloc(sizeof(" ++ t ++ "), FIC_TAG_CLOSURE, " ++ show (nptrOf fcs) ++ ");")
          emit (o ++ "->code = &" ++ codeName d ++ ";")
          forM_ (zip [0 :: Int ..] layout) $ \(i, (n, _, _)) ->
            mapM_ emit (fieldStores fcs i o (localName n))
          return ("(&" ++ o ++ "->h)")


-- a call of a value that is not a known clone: the function is evaluated first, then the arguments in order
unknownCall :: Info -> MExpr -> MExpr -> [MExpr] -> CG String
unknownCall info e h args =
  if null args || length args > maxArity
    then failWith ("a call of a function value with " ++ show (length args) ++ " arguments (the closure runtime has arities 1 to " ++ show maxArity ++ ")")
    else
      do  hv <- genExpr info h
          hr <- if atom h then return hv else
                  do  t <- fresh "h"
                      emit ("fic_ref " ++ t ++ " = " ++ hv ++ ";")
                      return t
          vals <- atomsTo info [ (a, abiClass (mRep a)) | a <- args ]
          let mask = sum [ 2 ^ i | (i, a) <- zip [0 :: Int ..] args, abiClass (mRep a) == CRef ] :: Int
          let call = "fic_ap" ++ show (length args) ++ "(" ++ hr ++ ", " ++ show mask ++ "u, "
                     ++ List.intercalate ", " [ wordMk (mRep a) v | (a, v) <- zip args vals ] ++ ")"
          adaptOwn (abiClass (mRep e)) (mRep e) (call ++ wordSel (mRep e))


-- the field classes of a struct class (for the elements, if the class is not one)
structFields :: Class -> [MExpr] -> [Class]
structFields c xs =
  case c of
    CStruct fs -> fs
    _ -> map (boxedClass . mRep) xs


-- arguments in order, each converted to the class the receiver holds it in (`adapt`);
-- anything that is not an atom goes to a temporary first
atomsTo :: Info -> [(MExpr, Class)] -> CG [String]
atomsTo info args =
  forM args $ \(a, target) ->
    do  v <- genExpr info a
        v' <- adaptOwn (mRep a) target v
        if atom a && mRep a == target
          then return v'
          else
            do  t <- fresh "a"
                emit (classType target ++ " " ++ t ++ " = " ++ v' ++ ";")
                return t


atoms :: Info -> [MExpr] -> CG [String]
atoms info args = atomsTo info [ (a, mRep a) | a <- args ]


-- a value of class `from` where `to` is wanted. A struct goes into a heap object where an unconstrained
-- variable, a closure word or an array element holds it, and comes out again
adapt :: Class -> Class -> String -> CG String
adapt from to v
  | from == to = return v
  | CStruct _ <- from, CRef <- to =
      do  t <- variable from v
          allocObj' [from] "FIC_TAG_BOX" [t]
  | CRef <- from, CStruct _ <- to =
      do  t <- variable from v
          return (unboxExpr to t)
  | otherwise = failWith ("internal: no conversion from " ++ classTag from ++ " to " ++ classTag to)


-- `adapt` for a value that is owned (an argument, the result of a call): a struct that comes out of a box takes a count on each
-- reference component and gives the box up (without counts it is the same view as `adapt`)
adaptOwn :: Class -> Class -> String -> CG String
adaptOwn from to v =
  do  rcMode <- gets gRc
      case (from, to) of
        (CRef, CStruct _) | rcMode ->
          do  t <- variable from v
              s <- variable to (unboxExpr to t)
              dupVars' to s
              emit ("fic_drop(" ++ t ++ ");")
              return s
        _ -> adapt from to v


-- | the leaves of a dying struct that no pattern variable takes over are dropped
unpackDrops :: String -> Class -> [(String, Class, [Int])] -> CG ()
unpackDrops s c bs =
  let taken = concat [ ix | (_, _, ix) <- bs ]
  in forM_ (zip [0 :: Int ..] (refPaths c (localName s))) (\(k, p) -> when (k `notElem` taken) (emit ("fic_drop(" ++ p ++ ");")))


dupVars :: [(String, Class)] -> CG ()
dupVars vs = mapM_ (\(n, c) -> dupVars' c (localName n)) vs


dropVars :: [(String, Class)] -> CG ()
dropVars vs = mapM_ (\(n, c) -> mapM_ (\p -> emit ("fic_drop(" ++ p ++ ");")) (refPaths c (localName n))) vs


dupVars' :: Class -> String -> CG ()
dupVars' c v = mapM_ (\p -> emit ("fic_dup(" ++ p ++ ");")) (refPaths c v)


-- the same for a pure `v` (a path into an object that is read only when a test has succeeded): no statements
adaptPure :: Class -> Class -> String -> CG String
adaptPure from to v
  | CRef <- from, CStruct _ <- to = return (unboxExpr to v)
  | otherwise = adapt from to v


unboxExpr :: Class -> String -> String
unboxExpr c v = fieldRead classType [c] 0 ("((" ++ objType [c] ++ " *)(" ++ v ++ "))")


-- the value in a variable (a plain name can be used several times)
variable :: Class -> String -> CG String
variable c v
  | not (null v) && all (\ch -> isAlphaNum ch || ch == '_') v = return v
  | otherwise =
      do  t <- fresh "u"
          emit ((if c == CRef then "fic_ref" else classType c) ++ " " ++ t ++ " = " ++ v ++ ";")
          return t


-- a heap object of a constructor or a list cell: header (tag) and fields
allocObj :: [Class] -> Int -> [String] -> CG String
allocObj [] tag [] = nullaryOwned tag
allocObj cs tag vals = allocObj' cs (show tag ++ "u") vals


-- nullary constructors are static immortal objects, one per tag (`fic_nul0` and `fic_nul1` are in fic_base.h)
nullary :: Int -> CG String
nullary tag =
  do  modify' (\g -> g { gNullary = Set.insert tag (gNullary g) })
      return ("(&fic_nul" ++ show tag ++ ")")


-- an owned reference to the static nullary object (with counts, a dup of an immortal object)
nullaryOwned :: Int -> CG String
nullaryOwned tag =
  do  p <- nullary tag
      rcMode <- gets gRc
      when rcMode (emit ("fic_dup(" ++ p ++ ");"))
      return p


allocObj' :: [Class] -> String -> [String] -> CG String
allocObj' cs tag vals =
  do  o <- fresh "o"
      vals' <- forM (zip cs vals) (\(c, v) -> case c of { CStruct _ -> variable c v; _ -> return v })
      emit (objType cs ++ " *" ++ o ++ " = (" ++ objType cs ++ " *)fic_alloc(sizeof(" ++ objType cs ++ "), " ++ tag ++ ", " ++ show (nptrOf cs) ++ ");")
      forM_ (zip [0 :: Int ..] vals') (\(i, v) -> mapM_ emit (fieldStores cs i o v))
      return ("(&" ++ o ++ "->h)")


-- a case: the scrutinee goes to a temporary, the branches are tried in order, each pattern gives
-- a condition and the variables it binds
genCase :: Info -> (MExpr -> CG ()) -> MExpr -> [(MPat, MExpr)] -> CG ()
genCase info finish scrut branches =
  do  v <- genExpr info scrut
      s <- fresh "s"
      emit (classType (mRep scrut) ++ " " ++ s ++ " = " ++ v ++ ";")
      emit ("(void)" ++ s ++ ";")
      go s branches
  where
    go _ [] = emit "FIC_UNREACHABLE();"
    go s ((pat, body) : rest) =
      do  (conds, binds) <- compilePat s (mRep scrut) pat
          emit ("if (" ++ (if null conds then "1" else List.intercalate " && " conds) ++ ") {")
          indented $
            do  forM_ binds $ \(n, c, path) ->
                  do  emit (classType c ++ " " ++ localName n ++ " = " ++ path ++ ";")
                      emit ("(void)" ++ localName n ++ ";")
                finish body
          emit "} else {"
          indented (go s rest)
          emit "}"


-- the conditions a value must meet and the variables bound, for a pattern against the C expression `path`
-- that holds a value of class `raw`
compilePat :: String -> Class -> MPat -> CG ([String], [(String, Class, String)])
compilePat path raw (MPat cls node) =
  case node of
    PWild -> return ([], [])
    PVar n -> do { p <- view; return ([], [(n, cls, p)]) }
    PAlias q n ->
      do  p <- view
          (cs, bs) <- compilePat path raw q
          return (cs, (n, cls, p) : bs)
    PLit l ->
      case l of
        LString str -> do { lit <- literal CRef (LString str); return (["fic_str_eq(" ++ path ++ ", " ++ lit ++ ")"], []) }
        _ -> do { lit <- literal cls l; return ([path ++ " == " ++ lit], []) }
    PTuple ps ->
      do  sp <- struct
          case sp of
            (path', CStruct fs) -> subs [ (path' ++ ".f" ++ show i, f, p) | (i, f, p) <- zip3 [0 :: Int ..] fs ps ]
            _ -> bad
    PRecord fs ->
      do  sp <- struct
          case sp of
            (path', CStruct fcs) ->
              do  bs <- forM fs $ \(i, n, c) ->
                    do  p <- adaptPure (fcs !! i) c (path' ++ ".f" ++ show i)
                        return (n, c, p)
                  return ([], bs)
            _ -> bad
    PCtor _ tag ps ->
      do  let test = if raw == CEnum then [path ++ " == " ++ show tag] else [tagTest tag]
          let fcs = map (boxedClass . mpRep) ps
          (cs, bs) <- subs [ (fieldRead classType fcs i ("((" ++ objType fcs ++ " *)(" ++ path ++ "))"), f, p) | (i, f, p) <- zip3 [0 :: Int ..] fcs ps ]
          return (test ++ cs, bs)
    PNil -> return ([tagTest 0], [])
    PCons h t ->
      do  let fcs = [boxedClass (mpRep h), CRef]
          let cell = "((" ++ objType fcs ++ " *)(" ++ path ++ "))"
          (cs, bs) <- subs [ (fieldRead classType fcs 0 cell, fcs !! 0, h), (fieldRead classType fcs 1 cell, CRef, t) ]
          return (tagTest 1 : cs, bs)
  where
    tagTest :: Int -> String
    tagTest tag = "((fic_hdr *)(" ++ path ++ "))->tag == " ++ show tag ++ "u"
    bad = failWith "internal: a pattern does not fit the class of its value" >> return ([], [])
    view = adaptPure raw cls path
    -- the struct a tuple or record pattern looks into: a boxed one is read out of its heap object first
    struct = case (raw, cls) of
      (CRef, CStruct _) -> do { p <- adaptPure raw cls path; return (p, cls) }
      _ -> return (path, raw)
    subs xs =
      do  rs <- forM xs (\(p, r, q) -> compilePat p r q)
          return (concatMap fst rs, concatMap snd rs)



literal :: Class -> MLit -> CG String
literal cls l =
  case l of
    LInt n -> return (if cls == CF64 then show (fromIntegral n :: Double) else if cls == CEnum then show n else "INT64_C(" ++ show n ++ ")")
    LFloat x -> return (show x)
    LChar c -> return ("UINT32_C(" ++ show c ++ ")")
    LUnit -> return "0"
    LString s -> staticLiteral s


-- a string literal is a static immortal object (one per text), counted like any other object
staticLiteral :: String -> CG String
staticLiteral str =
  do  known <- gets (Map.lookup str . gStrings)
      i <- case known of
             Just k -> return k
             Nothing ->
               do  k <- gets (Map.size . gStrings)
                   modify' (\g -> g { gStrings = Map.insert str k (gStrings g) })
                   return k
      return ("((fic_ref)&fic_slit" ++ show i ++ ")")


staticString :: String -> Int -> String
staticString str i =
  let (lit, n) = cString str
  in "static struct { fic_hdr h; int64_t len; int64_t cps; char data[" ++ show (n + 1) ++ "]; } fic_slit" ++ show i
     ++ " = { { FIC_IMMORTAL, FIC_TAG_STRING, 0, 0 }, " ++ show n ++ ", " ++ show (length str) ++ ", \"" ++ lit ++ "\" };"


-- a C string literal body and its length in bytes (UTF-8, octal escapes for anything but printable ASCII)
cString :: String -> (String, Int)
cString s =
  let bytes = concatMap utf8 s
  in (concatMap esc bytes, length bytes)
  where
    esc b
      | b == 34 = "\\\""
      | b == 92 = "\\\\"
      | b == 63 = "\\?"
      | b >= 32 && b < 127 = [toEnum b]
      | otherwise = ['\\', octal (b `shiftR` 6), octal (b `shiftR` 3), octal b]
    octal n = toEnum (48 + (n .&. 7))
    utf8 c
      | n < 0x80 = [n]
      | n < 0x800 = [0xC0 + shiftR n 6, 0x80 + (n .&. 0x3F)]
      | n < 0x10000 = [0xE0 + shiftR n 12, 0x80 + (shiftR n 6 .&. 0x3F), 0x80 + (n .&. 0x3F)]
      | otherwise = [0xF0 + shiftR n 18, 0x80 + (shiftR n 12 .&. 0x3F), 0x80 + (shiftR n 6 .&. 0x3F), 0x80 + (n .&. 0x3F)]
      where n = ord c



-- KERNEL FUNCTIONS


-- the tag of a JsArray (a vector of words) by the class of its elements
vecTag :: Class -> String
vecTag c = if boxedClass c == CRef then "FIC_TAG_VEC_REF" else "FIC_TAG_VEC_RAW"


-- the primitives of Elm.Kernel.JsArray (runtime/fic_jsarray.h): the elements are words of the key's class (a struct is boxed
-- there: `atomsTo` converts the arguments, `adapt` the results)
jsArrayCall :: Info -> Class -> String -> Key -> [MExpr] -> CG String
jsArrayCall info cls op key args =
  case (op, key, args) of
    ("singleton", Key [ByClass c], [x]) ->
      do  avs <- atomsTo info [(x, c)]
          let x' = avs !! 0
          return ("fic_ja_singleton(" ++ vecTag c ++ ", " ++ wordMk c x' ++ ")")
    ("length", _, [a]) -> do { avs <- atomsTo info [(a, CRef)]; return ("fic_ja_length(" ++ (avs !! 0) ++ ")") }
    ("initialize", Key [ByClass c], [n, off, f]) ->
      do  vs <- atomsTo info [(n, CI64), (off, CI64), (f, CRef)]
          return ("fic_ja_initialize(" ++ vecTag c ++ ", " ++ List.intercalate ", " vs ++ ")")
    ("initializeFromList", Key [ByClass c], [mx, ls]) ->
      do  avs <- atomsTo info [(mx, CI64), (ls, CRef)]
          let mx' = avs !! 0
              ls' = avs !! 1
          h <- helper (HFromList c)
          needObj [c, CRef]
          needClass info cls
          rest <- fresh "rest"
          arr <- fresh "arr"
          emit ("fic_ref " ++ rest ++ ";")
          emit ("fic_ref " ++ arr ++ " = " ++ h ++ "(" ++ mx' ++ ", " ++ ls' ++ ", &" ++ rest ++ ");")
          rcMode <- gets gRc
          when rcMode (emit ("fic_dup(" ++ rest ++ ");"))               -- the rest of the list is a borrowed tail of `ls`
          return ("(" ++ classType cls ++ "){ " ++ arr ++ ", " ++ rest ++ " }")
    ("unsafeGet", Key [ByClass c], [i, a]) ->
      do  vs <- atomsTo info [(i, CI64), (a, CRef)]
          adapt c cls ("fic_ja_get(" ++ List.intercalate ", " vs ++ ")" ++ wordSel c)
    ("unsafeSet", Key [ByClass c], [i, x, a]) ->
      do  avs <- atomsTo info [(i, CI64), (x, c), (a, CRef)]
          let i' = avs !! 0
              x' = avs !! 1
              a' = avs !! 2
          return ("fic_ja_set(" ++ i' ++ ", " ++ wordMk c x' ++ ", " ++ a' ++ ")")
    ("push", Key [ByClass c], [x, a]) ->
      do  avs <- atomsTo info [(x, c), (a, CRef)]
          let x' = avs !! 0
              a' = avs !! 1
          return ("fic_ja_push(" ++ wordMk c x' ++ ", " ++ a' ++ ")")
    (fold, Key [ByClass ca, ByClass cb], [f, acc, a]) | fold `elem` ["foldl", "foldr"] ->
      do  avs <- atomsTo info [(f, CRef), (acc, cb), (a, CRef)]
          let f' = avs !! 0
              acc' = avs !! 1
              a' = avs !! 2
          adaptOwn cb cls ("fic_ja_" ++ fold ++ "(" ++ f' ++ ", " ++ maskOf [ca, cb] ++ ", " ++ wordMk cb acc' ++ ", " ++ a' ++ ")" ++ wordSel cb)
    ("map", Key [ByClass ca, ByClass cb], [f, a]) ->
      do  avs <- atomsTo info [(f, CRef), (a, CRef)]
          let f' = avs !! 0
              a' = avs !! 1
          return ("fic_ja_map(" ++ vecTag cb ++ ", " ++ f' ++ ", " ++ maskOf [ca] ++ ", " ++ a' ++ ")")
    ("indexedMap", Key [ByClass ca, ByClass cb], [f, off, a]) ->
      do  avs <- atomsTo info [(f, CRef), (off, CI64), (a, CRef)]
          let f' = avs !! 0
              off' = avs !! 1
              a' = avs !! 2
          return ("fic_ja_indexedmap(" ++ vecTag cb ++ ", " ++ f' ++ ", " ++ maskOf [CI64, ca] ++ ", " ++ off' ++ ", " ++ a' ++ ")")
    ("slice", _, [from, to, a]) ->
      do  vs <- atomsTo info [(from, CI64), (to, CI64), (a, CRef)]
          return ("fic_ja_slice(" ++ List.intercalate ", " vs ++ ")")
    ("appendN", _, [n, d, s]) ->
      do  vs <- atomsTo info [(n, CI64), (d, CRef), (s, CRef)]
          return ("fic_ja_appendn(" ++ List.intercalate ", " vs ++ ")")
    _ -> failWith ("the kernel function Elm.JsArray." ++ op ++ " (with " ++ show (length args) ++ " arguments) is not supported by the C generator yet")
  where
    -- bit i set when argument i of the closure is a reference
    maskOf cs = show (sum [ 2 ^ i | (i, c) <- zip [0 :: Int ..] cs, boxedClass c == CRef ] :: Int) ++ "u"


kernelValue :: String -> Key -> CG String
kernelValue name key =
  case name of
    "elm/core:Elm.JsArray.empty" | Key [ByClass c] <- key -> return ("fic_ja_empty(" ++ vecTag c ++ ")")
    "elm/core:Basics.e" -> return "2.718281828459045"
    "elm/core:Basics.pi" -> return "3.141592653589793"
    "elm/core:Platform.Cmd.none" -> return "0"
    "elm/core:Platform.Sub.none" -> return "0"
    _ -> failWith ("kernel value `" ++ name ++ "` is not supported by the C generator yet")


data Num' = NInt | NFloat | NOther String


numberOf :: Key -> Num'
numberOf (Key parts) =
  case parts of
    ByType (TyCon "elm/core:Basics.Int" []) : _ -> NInt
    ByType (TyCon "elm/core:Basics.Float" []) : _ -> NFloat
    ByType (TyCon "elm/core:Char.Char" []) : _ -> NInt
    ByType t : _ -> NOther (mtypeText t)
    _ -> NOther "?"


kernelCall :: Info -> Class -> String -> Key -> [MExpr] -> CG String
kernelCall info cls name key args =
  case (name, args) of
    -- Elm's && and || do not evaluate the second operand when the first decides
    ("elm/core:Basics.and", [a, b]) -> shortCircuit a b True
    ("elm/core:Basics.or", [a, b]) -> shortCircuit a b False
    ("elm/core:List.cons", [h, t]) ->
      case key of
        Key [ByClass c] ->
          do  vals <- atomsTo info [(h, c), (t, CRef)]
              allocObj [c, CRef] 1 vals
        _ -> failWith "internal: the key of (::) is not a class"
    _ | Just op <- List.stripPrefix "elm/core:Elm.JsArray." name -> jsArrayCall info cls op key args
    _ | name `elem` ["elm/core:String.foldl", "elm/core:String.foldr"], Key [ByClass cb] <- key, [f, acc, s] <- args ->
      do  avs <- atomsTo info [(f, CRef), (acc, cb), (s, CRef)]
          let fn = if name == "elm/core:String.foldl" then "fic_us_foldl" else "fic_us_foldr"
          adaptOwn cb cls (fn ++ "(" ++ (avs !! 0) ++ ", " ++ (if boxedClass cb == CRef then "2u" else "0u") ++ ", " ++ wordMk cb (avs !! 1) ++ ", " ++ (avs !! 2) ++ ")" ++ wordSel cb)
    _ ->
      do  vals <- atoms info args
          case (name, vals) of
            ("elm/core:Basics.add", [a, b]) -> arith "FIC_ADD64" "+" a b
            ("elm/core:Basics.sub", [a, b]) -> arith "FIC_SUB64" "-" a b
            ("elm/core:Basics.mul", [a, b]) -> arith "FIC_MUL64" "*" a b
            ("elm/core:Basics.mulRound53", [a, b]) -> arith "FIC_MUL53" "*" a b
            ("elm/parser:Parser.Advanced.isSubString", [small, off, row, col, big]) ->
              do  needClass info cls
                  r <- fresh "pr"; c <- fresh "pc"; o <- fresh "po"
                  emit ("int64_t " ++ r ++ " = " ++ row ++ ", " ++ c ++ " = " ++ col ++ ";")
                  emit ("int64_t " ++ o ++ " = fic_pk_is_sub(" ++ small ++ ", " ++ off ++ ", &" ++ r ++ ", &" ++ c ++ ", " ++ big ++ ");")
                  return ("(" ++ classType cls ++ "){ " ++ o ++ ", " ++ r ++ ", " ++ c ++ " }")
            ("elm/parser:Parser.Advanced.findSubString", [small, off, row, col, big]) ->
              do  needClass info cls
                  r <- fresh "pr"; c <- fresh "pc"; o <- fresh "po"
                  emit ("int64_t " ++ r ++ " = " ++ row ++ ", " ++ c ++ " = " ++ col ++ ";")
                  emit ("int64_t " ++ o ++ " = fic_pk_find(" ++ small ++ ", " ++ off ++ ", &" ++ r ++ ", &" ++ c ++ ", " ++ big ++ ");")
                  return ("(" ++ classType cls ++ "){ " ++ o ++ ", " ++ r ++ ", " ++ c ++ " }")
            ("elm/parser:Parser.Advanced.isSubChar", [p, off, s]) -> return ("fic_pk_is_sub_char(" ++ p ++ ", " ++ off ++ ", " ++ s ++ ")")
            ("elm/parser:Parser.Advanced.isAsciiCode", [code, off, s]) -> return ("fic_pk_is_ascii(" ++ code ++ ", " ++ off ++ ", " ++ s ++ ")")
            ("elm/parser:Parser.Advanced.chompBase10", [off, s]) -> return ("fic_pk_chomp10(" ++ off ++ ", " ++ s ++ ")")
            ("elm/parser:Parser.Advanced.consumeBase", [base, off, s]) ->
              do  needClass info cls
                  t <- fresh "pt"; o <- fresh "po"
                  emit ("int64_t " ++ t ++ " = 0;")
                  emit ("int64_t " ++ o ++ " = fic_pk_consume(" ++ base ++ ", " ++ off ++ ", " ++ s ++ ", &" ++ t ++ ");")
                  return ("(" ++ classType cls ++ "){ " ++ o ++ ", " ++ t ++ " }")
            ("elm/parser:Parser.Advanced.consumeBase16", [off, s]) ->
              do  needClass info cls
                  t <- fresh "pt"; o <- fresh "po"
                  emit ("int64_t " ++ t ++ " = 0;")
                  emit ("int64_t " ++ o ++ " = fic_pk_consume16(" ++ off ++ ", " ++ s ++ ", &" ++ t ++ ");")
                  return ("(" ++ classType cls ++ "){ " ++ o ++ ", " ++ t ++ " }")
            ("elm/core:Debug.todo", [msg]) ->
              do  t <- fresh "todo"
                  emit (classType cls ++ " " ++ t ++ " = {0};")
                  emit ("fic_todo(" ++ msg ++ ");")
                  return t
            ("elm/core:String.append", [a, b]) -> return ("fic_str_append(" ++ a ++ ", " ++ b ++ ")")
            ("elm/core:String.contains", [a, b]) -> return ("fic_us_contains(" ++ a ++ ", " ++ b ++ ")")
            ("elm/core:String.startsWith", [a, b]) -> return ("fic_us_starts_with(" ++ a ++ ", " ++ b ++ ")")
            ("elm/core:String.endsWith", [a, b]) -> return ("fic_us_ends_with(" ++ a ++ ", " ++ b ++ ")")
            ("elm/core:String.indices", [a, b]) -> return ("fic_us_indexes(" ++ a ++ ", " ++ b ++ ")")
            ("elm/core:String.indexes", [a, b]) -> return ("fic_us_indexes(" ++ a ++ ", " ++ b ++ ")")
            ("elm/core:String.split", [a, b]) -> return ("fic_us_split(" ++ a ++ ", " ++ b ++ ")")
            ("elm/core:String.lines", [a]) -> return ("fic_us_lines(" ++ a ++ ")")
            ("elm/core:String.reverse", [a]) -> return ("fic_us_reverse(" ++ a ++ ")")
            ("elm/core:String.trim", [a]) -> return ("fic_us_trim(" ++ a ++ ")")
            ("elm/core:String.trimLeft", [a]) -> return ("fic_us_trim_left(" ++ a ++ ")")
            ("elm/core:String.trimRight", [a]) -> return ("fic_us_trim_right(" ++ a ++ ")")
            ("elm/core:String.filter", [f, s]) -> return ("fic_us_filter(" ++ f ++ ", " ++ s ++ ")")
            ("elm/core:String.any", [f, s]) -> return ("fic_us_any(" ++ f ++ ", " ++ s ++ ")")
            ("elm/core:String.all", [f, s]) -> return ("fic_us_all(" ++ f ++ ", " ++ s ++ ")")
            ("elm/core:Char.fromCode", [n]) -> return ("fic_us_from_code(" ++ n ++ ")")
            ("elm/core:Char.toLocaleUpper", [c]) -> return ("fic_us_cupper(" ++ c ++ ")")
            ("elm/core:Char.toLocaleLower", [c]) -> return ("fic_us_clower(" ++ c ++ ")")
            ("elm/core:String.toInt", [s]) -> maybeOf CI64 (\ok -> do { v <- fresh "iv"; emit ("int64_t " ++ v ++ " = 0;"); emit ("uint8_t " ++ ok ++ " = (uint8_t)fic_us_to_int(" ++ s ++ ", &" ++ v ++ ");"); return v })
            ("elm/core:String.toFloat", [s]) -> maybeOf CF64 (\ok -> do { v <- fresh "fv"; emit ("double " ++ v ++ " = 0;"); emit ("uint8_t " ++ ok ++ " = (uint8_t)fic_us_to_float(" ++ s ++ ", &" ++ v ++ ");"); return v })
            ("elm/core:String.uncons", [s]) ->
              do  let tupleC = CStruct [CU32, CRef]
                  needClass info tupleC
                  maybeOf CRef (\ok ->
                    do  c <- fresh "uc"; r <- fresh "ur"; v <- fresh "uv"
                        emit ("uint32_t " ++ c ++ " = 0;")
                        emit ("fic_ref " ++ r ++ " = NULL;")
                        emit ("uint8_t " ++ ok ++ " = (uint8_t)fic_us_uncons(" ++ s ++ ", &" ++ c ++ ", &" ++ r ++ ");")
                        emit ("fic_ref " ++ v ++ " = NULL;")
                        emit ("if (" ++ ok ++ ") {")
                        indented (do { b <- adapt tupleC CRef ("(" ++ classType tupleC ++ "){ " ++ c ++ ", " ++ r ++ " }"); emit (v ++ " = " ++ b ++ ";") })
                        emit "}"
                        return v)
            ("elm/core:String.length", [a]) -> return ("fic_us_length(" ++ a ++ ")")
            ("elm/core:String.slice", [a, b, s]) -> return ("fic_us_slice(" ++ a ++ ", " ++ b ++ ", " ++ s ++ ")")
            ("elm/core:String.cons", [c, s]) -> return ("fic_us_cons(" ++ c ++ ", " ++ s ++ ")")
            ("elm/core:String.join", [sep, l]) -> return ("fic_us_join(" ++ sep ++ ", " ++ l ++ ")")
            ("elm/core:String.words", [s]) -> return ("fic_us_words(" ++ s ++ ")")
            ("elm/core:String.toUpper", [s]) -> return ("fic_us_upper(" ++ s ++ ")")
            ("elm/core:String.toLower", [s]) -> return ("fic_us_lower(" ++ s ++ ")")
            ("elm/core:String.map", [f, s]) -> return ("fic_us_map(" ++ f ++ ", " ++ s ++ ")")
            ("elm/core:Char.toUpper", [c]) -> return ("fic_us_cupper(" ++ c ++ ")")
            ("elm/core:Char.toLower", [c]) -> return ("fic_us_clower(" ++ c ++ ")")
            ("elm/core:String.fromList", [l]) -> return ("fic_us_from_list(" ++ l ++ ")")
            ("elm/core:Char.toCode", [c]) -> return ("((int64_t)" ++ c ++ ")")
            ("elm/core:Basics.toFloat", [a]) -> return ("((double)" ++ a ++ ")")
            ("elm/core:Basics.round", [a]) -> return ("fic_round(" ++ a ++ ")")
            ("elm/core:Basics.floor", [a]) -> return ("fic_floor(" ++ a ++ ")")
            ("elm/core:Basics.ceiling", [a]) -> return ("fic_ceiling(" ++ a ++ ")")
            ("elm/core:Basics.truncate", [a]) -> return ("fic_truncate(" ++ a ++ ")")
            -- the functions of V8 (fdlibm, runtime/fic_fdlibm.h, decision L18): the digits equal node's
            ("elm/core:Basics.sqrt", [a]) -> return ("sqrt(" ++ a ++ ")")
            ("elm/core:Basics.logBase", [b, a]) -> return ("fic_fd_logbase(" ++ b ++ ", " ++ a ++ ")")
            ("elm/core:Basics.log", [a]) -> return ("fic_fd_log(" ++ a ++ ")")
            ("elm/core:Basics.sin", [a]) -> return ("fic_fd_sin(" ++ a ++ ")")
            ("elm/core:Basics.cos", [a]) -> return ("fic_fd_cos(" ++ a ++ ")")
            ("elm/core:Basics.tan", [a]) -> return ("fic_fd_tan(" ++ a ++ ")")
            ("elm/core:Basics.asin", [a]) -> return ("fic_fd_asin(" ++ a ++ ")")
            ("elm/core:Basics.acos", [a]) -> return ("fic_fd_acos(" ++ a ++ ")")
            ("elm/core:Basics.atan", [a]) -> return ("fic_fd_atan(" ++ a ++ ")")
            ("elm/core:Basics.atan2", [a, b]) -> return ("fic_fd_atan2(" ++ a ++ ", " ++ b ++ ")")
            ("elm/core:Basics.isNaN", [a]) -> return ("(uint8_t)(" ++ a ++ " != " ++ a ++ ")")
            ("elm/core:Basics.isInfinite", [a]) -> return ("(uint8_t)(isinf(" ++ a ++ ") != 0)")
            ("elm/core:Basics.xor", [a, b]) -> return ("(uint8_t)(" ++ a ++ " != " ++ b ++ ")")
            ("elm/core:Basics.fdiv", [a, b]) -> return ("(" ++ a ++ " / " ++ b ++ ")")
            ("elm/core:Basics.idiv", [a, b]) -> return ("fic_idiv(" ++ a ++ ", " ++ b ++ ")")
            ("elm/core:Basics.pow", [a, b]) ->
              case numberOf key of
                NInt -> return ("fic_ipow(" ++ a ++ ", " ++ b ++ ")")
                NFloat -> return ("fic_fd_pow(" ++ a ++ ", " ++ b ++ ")")
                NOther t -> unsupported ("^ at " ++ t)
            ("elm/core:Basics.modBy", [m, x]) -> return ("fic_modby(" ++ m ++ ", " ++ x ++ ")")
            ("elm/core:Basics.remainderBy", [m, x]) -> return ("fic_remby(" ++ m ++ ", " ++ x ++ ")")
            ("elm/core:Basics.negate", [a]) ->
              case numberOf key of
                NInt -> return ("FIC_NEG64(" ++ a ++ ")")
                NFloat -> return ("(-" ++ a ++ ")")
                NOther t -> unsupported ("negate at " ++ t)
            ("elm/core:Basics.gt", [a, b]) -> compare' ">" "fic_f_gt" a b
            ("elm/core:Basics.ge", [a, b]) -> compare' ">=" "fic_f_ge" a b
            ("elm/core:Basics.lt", [a, b]) -> compare' "<" "fic_f_lt" a b
            ("elm/core:Basics.le", [a, b]) -> compare' "<=" "fic_f_le" a b
            ("elm/core:Basics.eq", [a, b]) -> equality False a b
            ("elm/core:Basics.neq", [a, b]) -> equality True a b
            ("elm/core:Basics.not", [a]) -> return ("(!" ++ a ++ ")")
            -- Order: LT 0, EQ 1, GT 2 (a NaN compares as GT, as Elm's kernel does)
            ("elm/core:Basics.compare", [a, b]) ->
              case numberOf key of
                NInt -> return ("(" ++ a ++ " < " ++ b ++ " ? 0 : " ++ a ++ " == " ++ b ++ " ? 1 : 2)")
                NFloat -> return ("(" ++ a ++ " == " ++ b ++ " ? 1 : " ++ a ++ " < " ++ b ++ " ? 0 : 2)")
                NOther _ ->
                  do  c <- cmpOfKey a b
                      t <- fresh "c"
                      emit ("int " ++ t ++ " = " ++ c ++ ";")
                      return ("(" ++ t ++ " < 0 ? 0 : " ++ t ++ " == 0 ? 1 : 2)")
            -- Bitwise exactly as Elm (32 bit, shift count & 31, shiftRightZfBy unsigned); Bitwise64 (name provisional) on 64 bit, count & 63
            ("elm/core:Bitwise.and", [a, b]) -> return ("fic_bw_and(" ++ a ++ ", " ++ b ++ ")")
            ("elm/core:Bitwise.or", [a, b]) -> return ("fic_bw_or(" ++ a ++ ", " ++ b ++ ")")
            ("elm/core:Bitwise.xor", [a, b]) -> return ("fic_bw_xor(" ++ a ++ ", " ++ b ++ ")")
            ("elm/core:Bitwise.complement", [a]) -> return ("fic_bw_not(" ++ a ++ ")")
            ("elm/core:Bitwise.shiftLeftBy", [n, a]) -> return ("fic_bw_shl(" ++ n ++ ", " ++ a ++ ")")
            ("elm/core:Bitwise.shiftRightBy", [n, a]) -> return ("fic_bw_shr(" ++ n ++ ", " ++ a ++ ")")
            ("elm/core:Bitwise.shiftRightZfBy", [n, a]) -> return ("fic_bw_shrz(" ++ n ++ ", " ++ a ++ ")")
            ("elm/core:Bitwise64.and", [a, b]) -> return ("fic_bw64_and(" ++ a ++ ", " ++ b ++ ")")
            ("elm/core:Bitwise64.or", [a, b]) -> return ("fic_bw64_or(" ++ a ++ ", " ++ b ++ ")")
            ("elm/core:Bitwise64.xor", [a, b]) -> return ("fic_bw64_xor(" ++ a ++ ", " ++ b ++ ")")
            ("elm/core:Bitwise64.complement", [a]) -> return ("fic_bw64_not(" ++ a ++ ")")
            ("elm/core:Bitwise64.shiftLeftBy", [n, a]) -> return ("fic_bw64_shl(" ++ n ++ ", " ++ a ++ ")")
            ("elm/core:Bitwise64.shiftRightBy", [n, a]) -> return ("fic_bw64_shr(" ++ n ++ ", " ++ a ++ ")")
            ("elm/core:Bitwise64.shiftRightZfBy", [n, a]) -> return ("fic_bw64_shrz(" ++ n ++ ", " ++ a ++ ")")
            ("elm/core:Basics.append", [a, b]) ->
              case key of
                Key [ByApp AStr] -> return ("fic_str_append(" ++ a ++ ", " ++ b ++ ")")
                Key [ByApp (AList c)] -> do { h <- helper (HApp (boxedClass c)); needObj [boxedClass c, CRef]; return (h ++ "(" ++ a ++ ", " ++ b ++ ")") }
                _ -> unsupported "++ at this key"
            ("elm/core:String.fromInt", [a]) -> return ("fic_str_from_int(" ++ a ++ ")")
            ("elm/core:String.fromFloat", [a]) -> return ("fic_str_from_float(" ++ a ++ ")")
            ("elm/core:Debug.log", [tag, v]) -> debugLog tag v
            ("elm/core:Debug.toString", [v]) | Key [ByType t] <- key ->
              do  sb <- fresh "sb"
                  emit ("fic_sb " ++ sb ++ ";")
                  emit ("fic_sb_init(&" ++ sb ++ ");")
                  showStmt info t ("&" ++ sb) v
                  s <- fresh "s"
                  emit ("fic_ref " ++ s ++ " = fic_sb_str(&" ++ sb ++ ");")
                  return s
            _ -> unsupported ("the kernel function " ++ name ++ " (with " ++ show (length args) ++ " arguments)")
  where
    unsupported what = failWith (what ++ " is not supported by the C generator yet")
    unsupported' = unsupported

    -- a `Maybe` of a value of class c (Just is constructor 0, Nothing 1); `make` emits the statements that compute the
    -- flag (the name it is given) and the value
    maybeOf c make =
      do  ok <- fresh "ok"
          t <- fresh "m"
          v <- make ok
          needObj [c]
          emit ("fic_ref " ++ t ++ ";")
          emit ("if (" ++ ok ++ ") {")
          indented (do { o <- allocObj [c] 0 [v]; emit (t ++ " = " ++ o ++ ";") })
          emit "} else {"
          indented (do { o <- allocObj [] 1 []; emit (t ++ " = " ++ o ++ ";") })
          emit "}"
          return t

    arith intMacro op a b =
      case numberOf key of
        NInt -> return (intMacro ++ "(" ++ a ++ ", " ++ b ++ ")")
        NFloat -> return ("(" ++ a ++ " " ++ op ++ " " ++ b ++ ")")
        NOther t -> unsupported (op ++ " at " ++ t)

    compare' op floatFn a b =
      case numberOf key of
        NInt -> return ("(" ++ a ++ " " ++ op ++ " " ++ b ++ ")")
        -- Elm's JavaScript uses the operator itself when an operand is a literal, and `_Utils_cmp` otherwise: the two
        -- differ for a NaN (`nan > 1` is False, `nan > x` is True)
        NFloat | any isNumLit args -> return ("(" ++ a ++ " " ++ op ++ " " ++ b ++ ")")
               | otherwise -> return (floatFn ++ "(" ++ a ++ ", " ++ b ++ ")")
        NOther _ -> do { c <- cmpOfKey a b; return ("(" ++ c ++ " " ++ op ++ " 0)") }

    -- the sign of the comparison of two values of the exact type of the key (Elm's `_Utils_cmp`)
    cmpOfKey a b =
      case key of
        Key [ByType t] -> cmpExpr t a b
        _ -> unsupported' "comparison at this key"

    equality neg a b =
      case key of
        Key [ByType t] -> do { e <- eqExpr info t a b; return (if neg then "(!" ++ e ++ ")" else e) }
        _ -> unsupported' "equality at this key"

    shortCircuit a b isAnd =
      do  t <- fresh "t"
          a' <- genExpr info a
          emit ("uint8_t " ++ t ++ " = " ++ a' ++ ";")
          emit ("if (" ++ (if isAnd then "" else "!") ++ t ++ ") {")
          indented (genExpr info b >>= \b' -> emit (t ++ " = " ++ b' ++ ";"))
          emit "}"
          return t

    debugLog tag v =
      case key of
        Key [ByType TyUnit] ->
          do  emit ("fic_log_unit(" ++ tag ++ ");")
              return v
        Key [ByType (TyCon n [])] | Just shown <- lookup n shows' ->
          do  t <- fresh "l"
              emit (classType cls ++ " " ++ t ++ " = " ++ v ++ ";")
              sh <- fresh "sh"
              emit ("fic_ref " ++ sh ++ " = " ++ shown t ++ ";")
              emit ("fic_log(" ++ tag ++ ", " ++ sh ++ ");")
              dropIfRc sh
              return t
        Key [ByType t] ->
          do  sb <- fresh "sb"
              emit ("fic_sb " ++ sb ++ ";")
              emit ("fic_sb_init(&" ++ sb ++ ");")
              showStmt info t ("&" ++ sb) v
              s <- fresh "s"
              emit ("fic_ref " ++ s ++ " = fic_sb_str(&" ++ sb ++ ");")
              emit ("fic_log(" ++ tag ++ ", " ++ s ++ ");")
              dropIfRc s
              return v
        _ -> unsupported "Debug.log at this key"
    dropIfRc x = do { rcMode <- gets gRc; when rcMode (emit ("fic_drop(" ++ x ++ ");")) }
    shows' =
      [ ("elm/core:Basics.Int", \t -> "fic_str_from_int(" ++ t ++ ")")
      , ("elm/core:Basics.Float", \t -> "fic_str_from_float(" ++ t ++ ")")
      , ("elm/core:String.String", \t -> "fic_show_string(" ++ t ++ ")")
      ]


-- statements that print a value of an exact type into the buffer `sb` (a pointer) in Elm's Debug.toString format
showStmt :: Info -> MType -> String -> String -> CG ()
showStmt _ t sb v =
  case t of
    TyCon "elm/core:Basics.Int" [] -> emit ("fic_sb_int(" ++ sb ++ ", " ++ v ++ ");")
    TyCon "elm/core:Basics.Float" [] -> emit ("fic_sb_float(" ++ sb ++ ", " ++ v ++ ");")
    TyCon "elm/core:Char.Char" [] -> emit ("fic_sb_char(" ++ sb ++ ", " ++ v ++ ");")
    TyCon "elm/core:String.String" [] -> emit ("fic_sb_string(" ++ sb ++ ", " ++ v ++ ");")
    TyCon "elm/core:Basics.Bool" [] -> emit ("fic_sb_puts(" ++ sb ++ ", " ++ v ++ " ? \"True\" : \"False\");")
    TyUnit -> emit ("fic_sb_puts(" ++ sb ++ ", \"()\");")
    TyFun _ _ -> emit ("fic_sb_puts(" ++ sb ++ ", \"<function>\");")
    _ -> do { h <- helper (HShow t); emit (h ++ "(" ++ sb ++ ", " ++ v ++ ");") }


isNumLit :: MExpr -> Bool
isNumLit e = case mNode e of { MLit (LInt _) -> True; MLit (LFloat _) -> True; _ -> False }


-- the names of the local variables an expression reads
usedLocals :: MExpr -> Set.Set String
usedLocals e =
  Set.unions ((case mNode e of { MLocal n -> Set.singleton n; _ -> Set.empty }) : map usedLocals (children e))



-- GENERATED HELPERS: equality, comparison, list append and sorting (STAGE3-PLAN slice 4)
--
-- `==` and `compare` at an exact type that is not a scalar or a string become one C function per type
-- (`fic_eq_N`, `fic_cmp_N`), written after all clones; they call each other for the parts of the type (a recursive
-- type calls its own function). `++` on lists is one function per element class, sorts one per (element class, key type).
-- The functions are named when a clone uses them and written in `genHelpers`; their prototypes and the types only
-- they need are put where the line `HELPER_MARK` stands.


data HKey
  = HEq MType
  | HCmp MType
  | HApp Class
  | HFromList Class
  | HShow MType
  | HShowTree MType
  deriving (Eq, Ord)


failUnit :: String -> CG ()
failUnit msg = failWith msg >> return ()


helperMark :: String
helperMark = "/* HELPER_MARK */"


helper :: HKey -> CG String
helper k =
  do  known <- gets (Map.lookup k . gHelpers)
      case known of
        Just n -> return n
        Nothing ->
          do  i <- gets (Map.size . gHelpers)
              let n = prefix ++ show i
              modify' (\g -> g { gHelpers = Map.insert k n (gHelpers g), gPending = gPending g ++ [(k, n)] })
              return n
  where
    prefix =
      case k of
        HEq _ -> "fic_eq_"
        HCmp _ -> "fic_cmp_"
        HApp _ -> "fic_app_"
        HFromList _ -> "fic_jafl_"
        HShow _ -> "fic_show_"
        HShowTree _ -> "fic_showtree_"


-- the object layout / struct type a helper needs: defined at HELPER_MARK unless a clone defines it already
needObj :: [Class] -> CG ()
needObj cs =
  modify' (\g -> g { gExtraObjs = Set.insert cs (gExtraObjs g) })


needClass :: Info -> Class -> CG ()
needClass info c =
  case c of
    CStruct fs -> do { mapM_ (needClass info) fs; modify' (\g -> g { gExtraStructs = Set.insert fs (gExtraStructs g), gExtraObjs = Set.insert [c] (gExtraObjs g) }) }
    _ -> return ()


-- keep only the layouts no clone defines (done when the extras are written)
genHelpers :: Info -> CG ()
genHelpers info =
  do  pending <- gets gPending
      case pending of
        [] ->
          modify' (\g -> g { gExtraObjs = Set.difference (gExtraObjs g) (iObjs info), gExtraStructs = Set.difference (gExtraStructs g) (iStructs info) })
        (k, n) : rest ->
          do  modify' (\g -> g { gPending = rest, gWhere = n })
              genHelper info k n
              genHelpers info


clsOf :: Info -> MType -> Class
clsOf info = classOfM (Map.map usEnum (iUnions info))


-- the constructors of a custom type with the arguments of the exact type put in
ctorsOf :: Info -> String -> [MType] -> Maybe [(String, Int, [MType])]
ctorsOf info n args =
  do  u <- Map.lookup n (iUnions info)
      return [ (c, t, map substArgs fs) | (c, t, fs) <- usCtors u ]
  where
    substArgs ty =
      case ty of
        TyCon ('#' : ds) [] | [(i, "")] <- reads ds, i < length args -> args !! i
        TyCon c xs -> TyCon c (map substArgs xs)
        TyFun a b -> TyFun (substArgs a) (substArgs b)
        TyRecord fs -> TyRecord [ (f, substArgs x) | (f, x) <- fs ]
        TyTuple xs -> TyTuple (map substArgs xs)
        TyUnit -> TyUnit


isStringT :: MType -> Bool
isStringT t = case t of { TyCon "elm/core:String.String" [] -> True; _ -> False }


-- an expression for `a == b` at an exact type (a and b are atoms)
eqExpr :: Info -> MType -> String -> String -> CG String
eqExpr info t a b
  | isStringT t = return ("fic_str_eq(" ++ a ++ ", " ++ b ++ ")")
  | otherwise =
      case clsOf info t of
        CUnit -> return "1"
        CRef -> call
        CStruct _ -> call
        _ -> return ("(" ++ a ++ " == " ++ b ++ ")")
  where
    call = do { h <- helper (HEq t); return (h ++ "(" ++ a ++ ", " ++ b ++ ")") }


-- an expression for the sign of the comparison of two values at an exact type: Int, Char, Float, String, and
-- tuples and lists of these (a and b are atoms)
cmpExpr :: MType -> String -> String -> CG String
cmpExpr t a b =
  case t of
    TyCon "elm/core:Basics.Int" [] -> return ("fic_i_cmp(" ++ a ++ ", " ++ b ++ ")")
    TyCon "elm/core:Char.Char" [] -> return ("fic_i_cmp((int64_t)" ++ a ++ ", (int64_t)" ++ b ++ ")")
    TyCon "elm/core:Basics.Float" [] -> return ("fic_f_cmp(" ++ a ++ ", " ++ b ++ ")")
    _ | isStringT t -> return ("fic_str_cmp(" ++ a ++ ", " ++ b ++ ")")
    _ -> do { h <- helper (HCmp t); return (h ++ "(" ++ a ++ ", " ++ b ++ ")") }


-- the fields of a struct class (tuple or record), the value of field i of `v` at its own class
structField :: Info -> Class -> MType -> Int -> String -> CG String
structField info sc ty i v =
  case sc of
    CStruct fcs -> adapt (fcs !! i) (clsOf info ty) (v ++ ".f" ++ show i)
    _ -> failWith "internal: a tuple or record that is not a struct"


tagOf :: String -> String
tagOf x = "((fic_hdr *)(" ++ x ++ "))->tag"


genHelper :: Info -> HKey -> String -> CG ()
genHelper info k name =
  case k of
    HEq t -> withProto ("static uint8_t " ++ name ++ "(" ++ classType (clsOf info t) ++ " a, " ++ classType (clsOf info t) ++ " b)") (needClass info (clsOf info t) >> eqBody t)
    HCmp t -> withProto ("static int " ++ name ++ "(" ++ classType (clsOf info t) ++ " a, " ++ classType (clsOf info t) ++ " b)") (needClass info (clsOf info t) >> cmpBody t)
    HApp c -> withProto ("static fic_ref " ++ name ++ "(fic_ref xs, fic_ref ys)") (appBody c)
    HShow t -> withProto ("static void " ++ name ++ "(fic_sb *b, " ++ classType (clsOf info t) ++ " x)") (needClass info (clsOf info t) >> emit "(void)x;" >> showBody t)
    HShowTree e -> withProto ("static void " ++ name ++ "(fic_sb *b, fic_ref x, int *first)") (showTreeBody e)
    HFromList c -> withProto ("static fic_ref " ++ name ++ "(int64_t max, fic_ref xs, fic_ref *rest)") (fromListBody c)
  where
    withProto sig body =
      do  modify' (\g -> g { gProtos = (sig ++ ";") : gProtos g })
          emit (sig ++ " {")
          _ <- indented body
          emit "}"
          emit ""

    eqBody t =
      case t of
        TyTuple ts -> structEq t ts
        TyRecord fs -> structEq t (map snd fs)
        TyFun _ _ ->
          do  emit "if (a == b) return 1;"
              emit "fic_panic_eq_fun();"
              emit "return 0;"
        -- a type variable that no use fixes (`[] == []`, `List.maximum []`): no value of this type can exist at run time
        TyCon "ref" [] -> emit "(void)a; (void)b;" >> emit "return 1;"
        TyCon "elm/core:List.List" [e] -> listEq e
        TyCon "elm/core:Elm.JsArray.JsArray" [e] -> jsArrayEq e
        TyCon "elm/core:Dict.Dict" [kt, vt] -> dictEq kt vt
        TyCon n args | Just ctors <- ctorsOf info n args, Map.member n (iUnions info) -> customEq n ctors
        _ -> failUnit ("equality at " ++ mtypeText t ++ " is not supported by the C generator yet") >> emit "return 0;"

    structEq t ts =
      do  let sc = clsOf info t
          forM_ (zip [0 :: Int ..] ts) $ \(i, ty) ->
            do  x <- structField info sc ty i "a"
                y <- structField info sc ty i "b"
                e <- eqExpr info ty x y
                emit ("if (!" ++ e ++ ") return 0;")
          emit "return 1;"

    -- two JsArrays are equal when they have the same length and equal elements (Elm: `_Utils_eq` on JavaScript arrays)
    jsArrayEq e =
      do  let ec = clsOf info e
          needClass info ec
          emit "int64_t i, n;"
          emit "if (a == b) return 1;"
          emit "n = fic_ja_length(a);"
          emit "if (n != fic_ja_length(b)) return 0;"
          emit "for (i = 0; i < n; i++) {"
          indented $
            do  x <- adapt (boxedClass ec) ec ("fic_ja_data(a)[i]" ++ wordSel ec)
                y <- adapt (boxedClass ec) ec ("fic_ja_data(b)[i]" ++ wordSel ec)
                en <- eqExpr info e x y
                emit ("if (!" ++ en ++ ") return 0;")
          emit "}"
          emit "return 1;"

    listEq e =
      do  let ec = clsOf info e
          let fcs = [boxedClass ec, CRef]
          needObj fcs
          needClass info ec
          emit "for (;;) {"
          indented $
            do  emit "if (a == b) return 1;"
                emit ("if (" ++ tagOf "a" ++ " != " ++ tagOf "b" ++ ") return 0;")
                emit ("if (" ++ tagOf "a" ++ " == 0u) return 1;")
                emit (objType fcs ++ " *ca = (" ++ objType fcs ++ " *)a, *cb = (" ++ objType fcs ++ " *)b;")
                x <- readF fcs 0 "ca" ec
                y <- readF fcs 0 "cb" ec
                en <- eqExpr info e x y
                emit ("if (!" ++ en ++ ") return 0;")
                emit ("a = " ++ fl fcs 1 "ca" ++ "; b = " ++ fl fcs 1 "cb" ++ ";")
          emit "}"

    -- Elm compares two dictionaries as their association lists (`Dict.toList`), not as trees: the same entries in a
    -- differently shaped tree are equal. The tree is walked in order with an explicit stack (a node is
    -- RBNode_elm_builtin color key value left right, tag 0; the empty tree is tag 1).
    dictEq kt vt =
      do  let kc = clsOf info kt
          let vc = clsOf info vt
          let fcs = [CEnum, boxedClass kc, boxedClass vc, CRef, CRef]
          needObj fcs
          needClass info kc
          needClass info vc
          let cell = "(" ++ objType fcs ++ " *)"
          emit "if (a == b) return 1;"
          emit "fic_ref sa[128], sb[128];"
          emit "int na = 0, nb = 0;"
          emit "for (;;) {"
          indented $
            do  emit ("while (" ++ tagOf "a" ++ " == 0u) { sa[na++] = a; a = " ++ fl fcs 3 ("(" ++ cell ++ "a)") ++ "; }")
                emit ("while (" ++ tagOf "b" ++ " == 0u) { sb[nb++] = b; b = " ++ fl fcs 3 ("(" ++ cell ++ "b)") ++ "; }")
                emit "if (na == 0 || nb == 0) return na == nb;"
                emit "a = sa[--na]; b = sb[--nb];"
                ka <- readF fcs 1 ("(" ++ cell ++ "a)") kc
                kb <- readF fcs 1 ("(" ++ cell ++ "b)") kc
                ek <- eqExpr info kt ka kb
                emit ("if (!" ++ ek ++ ") return 0;")
                va <- readF fcs 2 ("(" ++ cell ++ "a)") vc
                vb <- readF fcs 2 ("(" ++ cell ++ "b)") vc
                ev <- eqExpr info vt va vb
                emit ("if (!" ++ ev ++ ") return 0;")
                emit ("a = " ++ fl fcs 4 ("(" ++ cell ++ "a)") ++ "; b = " ++ fl fcs 4 ("(" ++ cell ++ "b)") ++ ";")
          emit "}"

    customEq n ctors
      | maybe False usEnum (Map.lookup n (iUnions info)) = emit "return a == b;"
      | otherwise =
          do  emit "if (a == b) return 1;"
              emit ("if (" ++ tagOf "a" ++ " != " ++ tagOf "b" ++ ") return 0;")
              emit ("switch (" ++ tagOf "a" ++ ") {")
              forM_ ctors $ \(_, tag, fs) ->
                when (not (null fs)) $
                  do  let fcs = map (boxedClass . clsOf info) fs
                      needObj fcs
                      emit ("case " ++ show tag ++ "u: {")
                      indented $
                        do  emit (objType fcs ++ " *ca = (" ++ objType fcs ++ " *)a, *cb = (" ++ objType fcs ++ " *)b;")
                            forM_ (zip3 [0 :: Int ..] fs fcs) $ \(i, ty, _) ->
                              do  needClass info (clsOf info ty)
                                  x <- readF fcs i "ca" (clsOf info ty)
                                  y <- readF fcs i "cb" (clsOf info ty)
                                  en <- eqExpr info ty x y
                                  emit ("if (!" ++ en ++ ") return 0;")
                            emit "return 1;"
                      emit "}"
              emit "default: return 1;"
              emit "}"

    cmpBody t =
      case t of
        TyTuple ts -> structCmp t ts
        TyCon "ref" [] -> emit "(void)a; (void)b;" >> emit "return 0;"
        TyCon "elm/core:List.List" [e] -> listCmp e
        _ -> failUnit ("comparison at " ++ mtypeText t ++ " is not supported by the C generator yet") >> emit "return 0;"

    structCmp t ts =
      do  let sc = clsOf info t
          forM_ (zip [0 :: Int ..] ts) $ \(i, ty) ->
            do  x <- structField info sc ty i "a"
                y <- structField info sc ty i "b"
                c <- cmpExpr ty x y
                emit ("{ int c = " ++ c ++ "; if (c != 0) return c; }")
          emit "return 0;"

    listCmp e =
      do  let ec = clsOf info e
          let fcs = [boxedClass ec, CRef]
          needObj fcs
          needClass info ec
          emit "for (;;) {"
          indented $
            do  emit ("if (" ++ tagOf "a" ++ " == 0u) return " ++ tagOf "b" ++ " == 0u ? 0 : -1;")
                emit ("if (" ++ tagOf "b" ++ " == 0u) return 1;")
                emit (objType fcs ++ " *ca = (" ++ objType fcs ++ " *)a, *cb = (" ++ objType fcs ++ " *)b;")
                x <- readF fcs 0 "ca" ec
                y <- readF fcs 0 "cb" ec
                c <- cmpExpr e x y
                emit ("{ int c = " ++ c ++ "; if (c != 0) return c; }")
                emit ("a = " ++ fl fcs 1 "ca" ++ "; b = " ++ fl fcs 1 "cb" ++ ";")
          emit "}"

    -- Debug.toString at an exact type: Elm's format (decisions L16, L29)
    showBody t =
      case t of
        TyTuple ts ->
          do  emit "fic_sb_puts(b, \"(\");"
              forM_ (zip [0 :: Int ..] ts) $ \(i, ty) ->
                do  when (i > 0) (emit "fic_sb_puts(b, \",\");")
                    v <- structField info (clsOf info t) ty i "x"
                    showStmt info ty "b" v
              emit "fic_sb_puts(b, \")\");"
        TyRecord fs ->
          do  emit "fic_sb_puts(b, \"{ \");"
              forM_ (zip [0 :: Int ..] fs) $ \(i, (n, ty)) ->
                do  emit ("fic_sb_puts(b, \"" ++ (if i > 0 then ", " else "") ++ n ++ " = \");")
                    v <- structField info (clsOf info t) ty i "x"
                    showStmt info ty "b" v
              emit "fic_sb_puts(b, \" }\");"
        TyCon "elm/core:List.List" [e] ->
          do  let ec = clsOf info e
              let fcs = [boxedClass ec, CRef]
              needObj fcs
              needClass info ec
              emit "int first = 1;"
              emit "fic_sb_puts(b, \"[\");"
              emit ("while (" ++ tagOf "x" ++ " != 0u) {")
              indented $
                do  emit (objType fcs ++ " *c = (" ++ objType fcs ++ " *)x;")
                    emit "if (!first) fic_sb_puts(b, \",\");"
                    emit "first = 0;"
                    v <- readF fcs 0 "c" ec
                    showStmt info e "b" v
                    emit ("x = " ++ fl fcs 1 "c" ++ ";")
              emit "}"
              emit "fic_sb_puts(b, \"]\");"
        TyCon "elm/core:Dict.Dict" [kt, vt] ->
          do  emit "fic_sb_puts(b, \"Dict.fromList [\");"
              dictWalk kt vt "x" (\kk vv -> do { emit "fic_sb_puts(b, \"(\");"; showStmt info kt "b" kk; emit "fic_sb_puts(b, \",\");"; showStmt info vt "b" vv; emit "fic_sb_puts(b, \")\");" })
              emit "fic_sb_puts(b, \"]\");"
        TyCon "elm/core:Set.Set" [e] ->
          do  needObj [CRef]
              emit "fic_sb_puts(b, \"Set.fromList [\");"
              dictWalk e TyUnit (fl [CRef] 0 ("((" ++ objType [CRef] ++ " *)x)")) (\kk _ -> showStmt info e "b" kk)
              emit "fic_sb_puts(b, \"]\");"
        TyCon "elm/core:Array.Array" [e] ->
          do  let ec = clsOf info e
              let afcs = [CI64, CI64, CRef, CRef]
              needObj afcs
              needClass info ec
              th <- helper (HShowTree e)
              emit "int first = 1;"
              emit (objType afcs ++ " *a = (" ++ objType afcs ++ " *)x;")
              emit "fic_sb_puts(b, \"Array.fromList [\");"
              emit ("{ int64_t j, m = fic_ja_length(" ++ fl afcs 2 "a" ++ "); for (j = 0; j < m; j++) " ++ th ++ "(b, fic_ja_data(" ++ fl afcs 2 "a" ++ ")[j].p, &first); }")
              emit ("{ int64_t i, n = fic_ja_length(" ++ fl afcs 3 "a" ++ ");")
              emit "  for (i = 0; i < n; i++) {"
              emit "    if (!first) fic_sb_puts(b, \",\");"
              emit "    first = 0;"
              v <- adapt (boxedClass ec) ec ("fic_ja_data(" ++ fl afcs 3 "a" ++ ")[i]" ++ wordSel ec)
              indented (indented (showStmt info e "b" v))
              emit "  } }"
              emit "fic_sb_puts(b, \"]\");"
        TyCon n args | Just ctors <- ctorsOf info n args, Map.member n (iUnions info) -> customShow n ctors
        _ -> emit "fic_sb_puts(b, \"{}\");"          -- an opaque value (Regex): Elm prints {} (decision L29)

    -- the entries of a Dict in order (an explicit stack): `entry` prints one (key, value)
    dictWalk kt vt root entry =
      do  let kc = clsOf info kt
          let vc = clsOf info vt
          let fcs = [CEnum, boxedClass kc, boxedClass vc, CRef, CRef]
          needObj fcs
          needClass info kc
          needClass info vc
          let cell = "(" ++ objType fcs ++ " *)"
          emit "{ fic_ref st[128], t = (fic_ref)(" >> return ()
          emit ("  " ++ root ++ ");")
          emit "  int n = 0, dfirst = 1;"
          emit "  for (;;) {"
          emit ("    while (" ++ tagOf "t" ++ " == 0u) { st[n++] = t; t = " ++ fl fcs 3 ("(" ++ cell ++ "t)") ++ "; }")
          emit "    if (n == 0) break;"
          emit "    t = st[--n];"
          emit "    if (!dfirst) fic_sb_puts(b, \",\");"
          emit "    dfirst = 0;"
          kx <- readF fcs 1 ("(" ++ cell ++ "t)") kc
          vx <- readF fcs 2 ("(" ++ cell ++ "t)") vc
          _ <- indented (indented (entry kx vx))
          emit ("    t = " ++ fl fcs 4 ("(" ++ cell ++ "t)") ++ ";")
          emit "  } }"

    showTreeBody e =
      do  let ec = clsOf info e
          needObj [CRef]
          needClass info ec
          self <- gets (\g -> Map.findWithDefault "" (HShowTree e) (gHelpers g))
          emit "int64_t i, n;"
          emit ("fic_ref arr = " ++ fl [CRef] 0 ("((" ++ objType [CRef] ++ " *)x)") ++ ";")
          emit "n = fic_ja_length(arr);"
          emit ("if (" ++ tagOf "x" ++ " == 1u) {")
          indented $
            do  emit "for (i = 0; i < n; i++) {"
                emit "  if (!*first) fic_sb_puts(b, \",\");"
                emit "  *first = 0;"
                v <- adapt (boxedClass ec) ec ("fic_ja_data(arr)[i]" ++ wordSel ec)
                indented (showStmt info e "b" v)
                emit "}"
          emit "} else {"
          indented (emit ("for (i = 0; i < n; i++) " ++ self ++ "(b, fic_ja_data(arr)[i].p, first);"))
          emit "}"

    customShow n ctors
      | maybe False usEnum (Map.lookup n (iUnions info)) =
          do  emit "switch (x) {"
              forM_ ctors $ \(c, tag, _) -> emit ("case " ++ show tag ++ ": fic_sb_puts(b, \"" ++ c ++ "\"); break;")
              emit "default: break;"
              emit "}"
      | otherwise =
          do  emit ("switch (" ++ tagOf "x" ++ ") {")
              forM_ ctors $ \(c, tag, fs) ->
                do  emit ("case " ++ show tag ++ "u: {")
                    indented $
                      do  emit ("fic_sb_puts(b, \"" ++ c ++ "\");")
                          when (not (null fs)) $
                            do  let fcs = map (boxedClass . clsOf info) fs
                                needObj fcs
                                emit (objType fcs ++ " *o = (" ++ objType fcs ++ " *)x;")
                                forM_ (zip3 [0 :: Int ..] fs fcs) $ \(i, ty, _) ->
                                  do  needClass info (clsOf info ty)
                                      emit "{ int64_t s0;"
                                      emit "  fic_sb_puts(b, \" \");"
                                      emit "  s0 = b->n;"
                                      v <- readF fcs i "o" (clsOf info ty)
                                      indented (showStmt info ty "b" v)
                                      emit "  fic_sb_wrap_arg(b, s0); }"
                          emit "break;"
                    emit "}"
              emit "default: break;"
              emit "}"

    -- List.take-like copy of the first `max` elements of a list into a JsArray; the rest of the list is stored in *rest
    fromListBody c =
      do  let fcs = [c, CRef]
          needObj fcs
          emit "int64_t n = 0, i;"
          emit "fic_ref p = xs, r;"
          emit ("while (n < max && " ++ tagOf "p" ++ " != 0u) { n++; p = " ++ fl fcs 1 ("((" ++ objType fcs ++ " *)p)") ++ "; }")
          emit ("r = fic_ja_new(n, " ++ vecTag c ++ ");")
          emit "p = xs;"
          emit "for (i = 0; i < n; i++) {"
          indented $
            do  emit ("fic_ja_data(r)[i] = " ++ wordMk c (fl fcs 0 ("((" ++ objType fcs ++ " *)p)")) ++ ";")
                rcMode <- gets gRc
                when (rcMode && c == CRef) (emit ("fic_dup(" ++ fl fcs 0 ("((" ++ objType fcs ++ " *)p)") ++ ");"))
                emit ("p = " ++ fl fcs 1 ("((" ++ objType fcs ++ " *)p)") ++ ";")
          emit "}"
          emit "*rest = p;"
          emit "return r;"

    appBody c =
      do  let fcs = [c, CRef]
          needObj fcs
          emit "fic_ref res = ys;"
          emit "fic_ref *link = &res;"
          emit ("while (" ++ tagOf "xs" ++ " != 0u) {")
          indented $
            do  emit (objType fcs ++ " *c = (" ++ objType fcs ++ " *)xs;")
                emit (objType fcs ++ " *n = (" ++ objType fcs ++ " *)fic_alloc(sizeof(" ++ objType fcs ++ "), 1u, " ++ show (nptrOf fcs) ++ ");")
                mapM_ emit (fieldStores fcs 0 "n" (fl fcs 0 "c"))
                rcMode <- gets gRc
                when (rcMode && c == CRef) (emit ("fic_dup(" ++ fl fcs 0 "c" ++ ");"))
                emit ("n->" ++ memberOf fcs 1 ++ " = ys;")
                emit ("*link = &n->h; link = &n->" ++ memberOf fcs 1 ++ "; xs = " ++ fl fcs 1 "c" ++ ";")
          emit "}"
          emit "return res;"


-- the value of field i of the object `p` (a pointer to the object struct, evaluated several times)
fl :: [Class] -> Int -> String -> String
fl = fieldRead classType


-- field i of the object `p` as a value of class `target` (a struct is unboxed)
readF :: [Class] -> Int -> String -> Class -> CG String
readF cs i p target = adapt (cs !! i) target (fl cs i p)


-- a condition without a redundant outer pair of parentheses (`if ((a == b))` is a warning of clang)
condText :: String -> String
condText s =
  case s of
    '(' : rest | not (null rest), last rest == ')', balanced 1 (init rest) -> init rest
    _ -> s
  where
    -- the opening parenthesis is closed only by the last character: the depth never reaches 0 inside
    balanced :: Int -> String -> Bool
    balanced d str =
      case str of
        [] -> d == 1
        c : cs
          | c == '(' -> balanced (d + 1) cs
          | c == ')' -> d > 1 && balanced (d - 1) cs
          | otherwise -> balanced d cs
