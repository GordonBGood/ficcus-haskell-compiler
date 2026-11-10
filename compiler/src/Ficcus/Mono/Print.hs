{-# OPTIONS_GHC -Wall #-}
module Ficcus.Mono.Print
  ( renderProgram
  , renderClone
  , keyTextIx
  , renderDef
  , renderExpr
  )
  where


-- Ficcus, stage (iii): the `.mono` text (`elm make x.fic --output=x.mono`).
--
-- Slice 0 prints, for every module (project modules first, then packages, by name):
--   mark <id>   v0=<kind>[+equatable][+printed] ...      for each definition with a keyed or row variable
--   clone cN   def: <id>   key: ()   kind: value|function   init: i   needs: <ids>
--                                                       the single clone of each monomorphic top level definition
-- Bodies and the clones of polymorphic definitions come with the specializer (slice 1 onwards).
-- The printer of bodies (`renderExpr`) is the one the specializer will use; the layout is that of `.types`.


import qualified Data.List as List
import Ficcus.Mono.Overlay (overlayModuleName)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import Ficcus.Mono.Class
import Ficcus.Mono.Facts
import Ficcus.Mono.Ir
import Ficcus.Mono.Marks


renderProgram :: [ModuleFacts] -> Maybe (Either [String] MProgram) -> [String]
renderProgram allModules program =
  header ++ concat (snd (List.mapAccumL one 0 modules)) ++ programLines
  where
    -- the overlay module (Ficcus.Mono.Overlay) is not part of the project: its marks and clones table stay out of the listing
    modules = filter (\m -> mfName m /= "author/project:" ++ overlayModuleName) allModules
    programLines =
      case program of
        Nothing -> []
        Just (Left errs) -> "-- program: not specialized" : [ "!! " ++ e | e <- errs ]
        Just (Right p) ->
          ("-- program: " ++ show (length (mpClones p)) ++ " clones, reachable from main, dependencies first") : concatMap (renderClone (Map.fromList [ (k, c) | c <- mpClones p, let CloneId k = mdClone c ])) (mpClones p)

    marks = compute allModules
    header = [ "-- mono: stage (iii) " ++ stageLabel ++ ", modules=" ++ show (length modules) ]

    one :: Int -> ModuleFacts -> (Int, [String])
    one next m =
      let kindsOf = Map.fromList [ (dfId d, dfKinds d) | d <- mfDefs m ]
          markLines = [ l | d <- mfDefs m, Just l <- [markLine marks d] ]
          mono = [ i | i <- List.sortOn ifIndex (mfInits m), null (Map.findWithDefault [] (ifId i) kindsOf) ]
          defs = zipWith (cloneOf kindsOf) [next ..] mono
          cloneOfId = Map.fromList [ (ifId i, CloneId n) | (n, i) <- zip [next ..] mono ]
          cloneLines = [ renderDef def { mdNeeds = [ c | n <- ifNeeds i, Just c <- [Map.lookup n cloneOfId] ] } | (i, def) <- defs ]
      in
      ( next + length mono
      , ("-- module " ++ mfName m ++ (if mfProject m then " (project)" else " (package)")) : markLines ++ cloneLines
      )
      where
        cloneOf _ n i =
          (i, MDef (CloneId n) (ifId i) (Key []) (if ifValue i then Value else Function) [] CRef Nothing (Just (ifIndex i)) [] Nothing [0 ..])


markLine :: Marks -> DefFact -> Maybe String
markLine marks d =
  let parts = [ (i, kind, marksOf marks (dfId d) i) | (i, kind) <- zip [0 ..] (dfKinds d) ]
      shown (i, kind, ms) = "v" ++ show i ++ "=" ++ kind ++ concatMap markWord (Set.toList ms)
      markWord Equatable = "+equatable"
      markWord Printed = "+printed"
      interesting (_, kind, ms) = kind == "row" || isKeyed kind ms
  in
  if any interesting parts
    then Just ("mark " ++ dfId d ++ "   " ++ unwords (map shown parts))
    else Nothing


-- | the slice of STAGE3-PLAN.md the output format belongs to
stageLabel :: String
stageLabel = "slice 3b"


renderDef :: MDef -> String
renderDef d =
  let CloneId n = mdClone d
  in "clone c" ++ show n ++ "   def: " ++ mdName d ++ "   key: " ++ keyText (mdKey d)
     ++ "   kind: " ++ (case mdKind d of { Value -> "value"; Function -> "function" })
     ++ maybe "" (\i -> "   init: " ++ show i) (mdInit d)
     ++ "   needs: " ++ List.intercalate "," [ "c" ++ show k | CloneId k <- mdNeeds d ]


-- | the readable name of a keyed clone: `limit__i64`, `limit__f64`; exact types other than Int and Float are
-- spelled `t`, a class part by its class (the C names add a counter)
cloneLabel :: MDef -> String
cloneLabel d =
  case mdKey d of
    Key [] -> ""
    Key parts -> "   name: " ++ baseName ++ concatMap (\p -> "__" ++ part p) parts
  where
    baseName = reverse (takeWhile (/= '.') (reverse (mdName d)))
    part p =
      case p of
        ByType (TyCon "elm/core:Basics.Int" []) -> "i64"
        ByType (TyCon "elm/core:Basics.Float" []) -> "f64"
        ByType _ -> "t"
        ByClass c -> classText c
        ByApp AStr -> "str"
        ByApp (AList c) -> "list_" ++ classText c
        ByLayout _ -> "row"


-- | the key of a clone with the scheme index of each variable: a local function shows only its own
-- variables (`v1=...`), those of the enclosing definitions are in the `outer:` part
keyTextIx :: [Int] -> Key -> String
keyTextIx ixs (Key parts) =
  "(" ++ List.intercalate "; " (zipWith (\i p -> "v" ++ show i ++ "=" ++ keyPartText p) (ixs ++ [0 ..]) parts) ++ ")"


-- | a clone of the program: its line and its body. `byId` finds the owner clones.
renderClone :: Map.Map Int MDef -> MDef -> [String]
renderClone byId d =
  let CloneId n = mdClone d
      owner = maybe "" (\(CloneId o) -> "   lifted-from: c" ++ show o) (mdLifted d)
      ownerChain m =
        case mdLifted m of
          Nothing -> []
          Just (CloneId o) ->
            case Map.lookup o byId of
              Nothing -> []
              Just od -> [ "c" ++ show o ++ " " ++ keyTextIx (mdVars od) (mdKey od) | not (isEmptyKey (mdKey od)) ] ++ ownerChain od
      outer = case ownerChain d of { [] -> ""; cs -> "   outer: " ++ List.intercalate ", " cs }
  in
  ( "clone c" ++ show n ++ "   def: " ++ mdName d ++ "   key: " ++ keyTextIx (mdVars d) (mdKey d) ++ outer ++ cloneLabel d
    ++ "   kind: " ++ (case mdKind d of { Value -> "value"; Function -> "function" })
    ++ "   params: " ++ unwords [ pn ++ ":" ++ classText pc | (pn, pc) <- mdParams d ]
    ++ "   result: " ++ classText (mdResult d) ++ owner )
  : maybe [] (renderExpr 1) (mdBody d)
  where
    isEmptyKey (Key ps) = null ps


-- | a body, indented, one node per line with its class
renderExpr :: Int -> MExpr -> [String]
renderExpr depth (MExpr cls node) =
  case node of
    MLit l -> line ("Lit " ++ litText l)
    MLocal n -> line ("Local " ++ n)
    MGlobal (CloneId n) -> line ("Global c" ++ show n)
    MKernel n k -> line ("Kernel " ++ n ++ " " ++ keyText k)
    MCtor n tag k -> line ("Ctor " ++ n ++ " tag " ++ show tag ++ " " ++ keyText k)
    MCall f args -> line "Call" ++ kids (f : args)
    MLam ps b -> line ("Lambda " ++ unwords [ n ++ ":" ++ classText c | (n, c) <- ps ]) ++ kids [b]
    MIf bs e -> line "If" ++ kids (concat [ [c, b] | (c, b) <- bs ] ++ [e])
    MLetVal n v b -> line ("Let " ++ n) ++ kids [v, b]
    MSeq a b -> line "Seq" ++ kids [a, b]
    MCase s bs -> line "Case" ++ kids [s] ++ concat [ [pad (depth + 1) ("branch " ++ patText p)] ++ renderExpr (depth + 2) b | (p, b) <- bs ]
    MAccess x f i -> line ("Access ." ++ f ++ " #" ++ show i) ++ kids [x]
    MUpdate x fs -> line ("Update " ++ unwords (map fst fs)) ++ kids (x : map snd fs)
    MRecord fs -> line ("Record " ++ unwords (map fst fs)) ++ kids (map snd fs)
    MTuple xs -> line "Tuple" ++ kids xs
    MList xs -> line "List" ++ kids xs
    MDup vs e -> line ("Dup " ++ unwords (map fst vs)) ++ kids [e]
    MDrop vs e -> line ("Drop " ++ unwords (map fst vs)) ++ kids [e]
    MOwn e -> line "Own" ++ kids [e]
  where
    line s = [pad depth (s ++ " :: " ++ classText cls)]
    kids = concatMap (renderExpr (depth + 1))
    pad n s = replicate (2 * n) ' ' ++ s


litText :: MLit -> String
litText l =
  case l of
    LInt n -> show n
    LFloat x -> show x
    LChar c -> "'" ++ show c ++ "'"
    LString s -> show s
    LUnit -> "()"


patText :: MPat -> String
patText (MPat cls node) =
  (case node of
    PWild -> "_"
    PVar n -> n
    PLit l -> litText l
    PCtor n tag ps -> unwords (n : ("#" ++ show tag) : map patText ps)
    PRecord ns -> "{" ++ List.intercalate "," [ n ++ "#" ++ show i ++ ":" ++ classText c | (i, n, c) <- ns ] ++ "}"
    PTuple ps -> "(" ++ List.intercalate ", " (map patText ps) ++ ")"
    PCons a b -> patText a ++ " :: " ++ patText b
    PNil -> "[]"
    PAlias p n -> patText p ++ " as " ++ n)
  ++ " :: " ++ classText cls
