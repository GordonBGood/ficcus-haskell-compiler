{-# LANGUAGE OverloadedStrings, PatternGuards #-}
module Make
  ( Flags(..)
  , Output(..)
  , ReportType(..)
  , run
  , reportType
  , output
  , docsFile
  )
  where


import qualified Data.ByteString.Builder as B
import System.Exit (ExitCode(..), exitWith)
import System.IO (hPutStrLn, stderr)
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Maybe as Maybe
import qualified Data.NonEmptyList as NE
import qualified System.Directory as Dir
import qualified System.Environment
import qualified System.FilePath as FP

import qualified AST.Optimized as Opt
import qualified AST.Prim.Module as Module
import qualified Build
import qualified Elm.Details as Details
import qualified Ficcus.Flags as Flags
import qualified Ficcus.Mono.CGen as CGen
import qualified Ficcus.Mono.Facts as Facts
import qualified Ficcus.Mono.Ir as Mono
import qualified Ficcus.Mono.Marks as Marks
import qualified Ficcus.Mono.Modules as Modules
import qualified Ficcus.Mono.Overlay as Overlay
import qualified Ficcus.Mono.Print as Print
import qualified Ficcus.Mono.Rc as Rc
import qualified Ficcus.Mono.RcCheck as RcCheck
import qualified Ficcus.Mono.Spec as Spec
import qualified File
import qualified Generate
import qualified Generate.Html as Html
import qualified Reporting
import qualified Reporting.Exit as Exit
import qualified Reporting.Task as Task
import qualified Root as R
import Terminal (Parser(..))



readMaybeInt :: String -> Maybe Int
readMaybeInt s = case reads s of { [(k, "")] -> Just k; _ -> Nothing }


-- Ficcus: report problems of the specializer or the C generator and stop
failWith :: [String] -> Task a
failWith msgs =
  Task.io $
    do  hPutStrLn stderr ("-- FICCUS: the program cannot be compiled to C yet --------------------------------\n\n" ++ unlines msgs)
        exitWith (ExitFailure 1)



-- FLAGS


data Flags =
  Flags
    { _debug :: Bool
    , _optimize :: Bool
    , _output :: Maybe Output
    , _report :: Maybe ReportType
    , _docs :: Maybe FilePath
    , _rc :: Bool                -- Ficcus: --output=x.c with reference counting (stage iv, `--rc`)
    }


data Output
  = JS FilePath
  | Html FilePath
  | C FilePath                 -- the dump of the optimized graph (milestone 1), `--output=x.optc`
  | FicC FilePath              -- the generated C of the specializer (stage iii), `--output=x.c`
  | Types FilePath
  | Mono FilePath
  | DevNull


data ReportType
  = Json



-- RUN


type Task a = Task.Task Exit.Make a


run :: [FilePath] -> Flags -> IO ()
run paths flags@(Flags _ _ _ report _ _) =
  do  style <- getStyle report
      maybeRoot <- R.findRoot
      Reporting.attemptWithStyle style Exit.makeToReport $
        case maybeRoot of
          Just root -> runHelp root paths style flags
          Nothing   -> return $ Left $ Exit.MakeNoOutline


runHelp :: R.Root -> [FilePath] -> Reporting.Style -> Flags -> IO (Either Exit.Make ())
runHelp root paths style (Flags debug optimize maybeOutput _ maybeDocs rcMode) =
  R.withRootLock root $ \writer stuff ->
  Task.run $
  do  desiredMode <- getMode debug optimize
      case maybeOutput of
        Just (Types _) -> Task.io (Flags.setTypedOutput True)
        Just (Mono _)  -> Task.io (Flags.setTypedOutput True >> Flags.setKeepModules True)
        Just (FicC _)  -> Task.io (Flags.setTypedOutput True >> Flags.setKeepModules True)
        _              -> return ()
      details <- Task.eio Exit.MakeBadDetails (Details.load writer style root stuff)
      case paths of
        [] ->
          do  exposed <- getExposed details
              buildExposed writer style root stuff details maybeDocs exposed

        p:ps ->
          do  -- Ficcus: the elm/core overlay is an extra root module of the `.c` and `.mono` builds
              overlayPaths <-
                case maybeOutput of
                  Just (Mono _) -> Task.io (writeOverlay root)
                  Just (FicC _) -> Task.io (writeOverlay root)
                  _ -> return []
              artifacts <- buildPaths writer style root stuff details (NE.List p (ps ++ overlayPaths))
              case maybeOutput of
                Nothing ->
                  case getMains artifacts of
                    [] ->
                      return ()

                    [name] ->
                      do  builder <- toBuilder stuff details desiredMode artifacts
                          generate writer style "index.html" (Html.sandwich name builder) (NE.List name [])

                    name:names ->
                      do  builder <- toBuilder stuff details desiredMode artifacts
                          generate writer style "elm.js" builder (NE.List name names)

                Just DevNull ->
                  return ()

                Just (JS target) ->
                  case getNoMains artifacts of
                    [] ->
                      do  builder <- toBuilder stuff details desiredMode artifacts
                          generate writer style target builder (Build.getRootNames artifacts)

                    name:names ->
                      Task.throw (Exit.MakeNonMainFilesIntoJavaScript name names)

                Just (Types target) ->
                  do  builder <- Task.io (Generate.typeDumps stuff artifacts)
                      generate writer style target builder (Build.getRootNames artifacts)

                Just (Mono target) ->
                  -- Ficcus stage (iii) slice 0: the clone table and marks; the type dump is written beside it
                  do  typesBuilder <- Task.io (Generate.typeDumps stuff artifacts)
                      Task.io (Dir.createDirectoryIfMissing True (FP.takeDirectory target))
                      Task.io (File.writeBuilder writer (FP.replaceExtension target ".types") typesBuilder)
                      facts <- Task.io Facts.takeAll
                      mods <- Task.io Modules.takeAll
                      let program = if null mods then Nothing else Spec.specialize mods (Marks.compute facts)
                      generate writer style target (B.stringUtf8 (unlines (Print.renderProgram facts program))) (Build.getRootNames artifacts)

                Just (FicC target) ->
                  -- Ficcus stage (iii): specialize, then generate C
                  do  facts <- Task.io Facts.takeAll
                      mods <- Task.io Modules.takeAll
                      case Spec.specialize mods (Marks.compute facts) of
                        Nothing -> failWith ["no `main` in the project"]
                        Just (Left errs) -> failWith errs
                        Just (Right program) -> do
                          -- with `--rc`: the Rc pass, then its independent checker, then the generator with counts
                          -- FICCUS_RC_MUTATE=n (tests of the checker): remove the n-th dup/drop the pass inserted, then check
                          mutation <- Task.io (System.Environment.lookupEnv "FICCUS_RC_MUTATE")
                          -- "rN": only the S4 sites (drop specializations, tokens, reuses)
                          let mutated prog = case mutation of
                                               Just ('r' : digits) | Just k <- readMaybeInt digits ->
                                                 maybe (Left ["FICCUS_RC_MUTATE: there is no reset or reuse number " ++ show k]) Right (Rc.rcMutate True k prog)
                                               _ -> case mutation >>= readMaybeInt of
                                                      Nothing -> Right prog
                                                      Just k -> maybe (Left ["FICCUS_RC_MUTATE: there is no dup or drop number " ++ show k]) Right (Rc.rcMutate False k prog)
                          -- FICCUS_RC_DUMP=text (debugging): print the counted clones whose definition name contains the text, before the check
                          dumpText <- Task.io (System.Environment.lookupEnv "FICCUS_RC_DUMP")
                          let rced = if rcMode then Rc.rcProgram program >>= mutated else Right program
                          case (dumpText, rced) of
                            (Just pat, Right prog) ->
                              Task.io (mapM_ (hPutStrLn stderr) (concat [ Print.renderClone Map.empty d | d <- Mono.mpClones prog, pat `List.isInfixOf` Mono.mdName d ]))
                            _ -> return ()
                          let counted = if rcMode then rced >>= \counted0 -> (case RcCheck.rcCheck counted0 of { [] -> Right counted0; errs -> Left errs }) else Right program
                          case counted of
                            Left errs -> failWith errs
                            Right program' ->
                              case CGen.generate rcMode program' of
                                Left errs -> failWith errs
                                Right text -> generate writer style target (B.stringUtf8 text) (Build.getRootNames artifacts)

                Just (C target) ->
                  case getNoMains artifacts of
                    [] ->
                      do  builder <- Task.mapError Exit.MakeBadGenerate (Generate.c stuff details artifacts)
                          generate writer style target builder (Build.getRootNames artifacts)

                    name:names ->
                      Task.throw (Exit.MakeNonMainFilesIntoJavaScript name names)

                Just (Html target) ->
                  do  name <- hasOneMain artifacts
                      builder <- toBuilder stuff details desiredMode artifacts
                      generate writer style target (Html.sandwich name builder) (NE.List name [])



-- Ficcus: write the overlay module (Ficcus.Mono.Overlay) into `elm-stuff/ficcus-overlay/` of the project and
-- make that directory a source directory for this build; the result is the path to add to the root files
writeOverlay :: R.Root -> IO [FilePath]
writeOverlay root =
  do  let dir = R.toAbsolutePath root (R.Relative "elm-stuff/ficcus-overlay")
      let file = dir FP.</> Overlay.overlayFileName
      Dir.createDirectoryIfMissing True dir
      old <- Dir.doesFileExist file
      same <- if old then (== Overlay.overlaySource) <$> readFileStrict file else return False
      if same then return () else writeFile file Overlay.overlaySource
      writeFile (dir FP.</> Overlay.bitwise64FileName) Overlay.bitwise64Source
      Flags.setExtraSrcDir (Just dir)
      -- the elm/parser overlay is a root module of the projects that depend on elm/parser
      let elmJson = R.toAbsolutePath root (R.Relative "elm.json")
      hasJson <- Dir.doesFileExist elmJson
      jsonText <- if hasJson then readFileStrict elmJson else return ""
      let usesParser = "elm/parser" `List.isInfixOf` jsonText
      let usesRandom = "elm/random" `List.isInfixOf` jsonText
      let optional used name source =
            do  let f = dir FP.</> name
                if used
                  then writeFile f source >> return [f]
                  else do  gone <- Dir.doesFileExist f
                           if gone then Dir.removeFile f else return ()
                           return []
      parserFiles <- optional usesParser Overlay.parserFileName Overlay.parserSource
      randomFiles <- optional usesRandom Overlay.randomFileName Overlay.randomSource
      return (file : parserFiles ++ randomFiles)


readFileStrict :: FilePath -> IO String
readFileStrict path =
  do  s <- readFile path
      length s `seq` return s



-- GET INFORMATION


getStyle :: Maybe ReportType -> IO Reporting.Style
getStyle report =
  case report of
    Nothing -> Reporting.terminal
    Just Json -> return Reporting.json


getMode :: Bool -> Bool -> Task DesiredMode
getMode debug optimize =
  case (debug, optimize) of
    (True , True ) -> Task.throw Exit.MakeCannotOptimizeAndDebug
    (True , False) -> return Debug
    (False, False) -> return Dev
    (False, True ) -> return Prod


getExposed :: Details.Details -> Task (NE.List Module.Name)
getExposed (Details.Details _ validOutline _ _ _ _) =
  case validOutline of
    Details.ValidApp _ ->
      Task.throw Exit.MakeAppNeedsFileNames

    Details.ValidPkg _ exposed _ ->
      case exposed of
        [] -> Task.throw Exit.MakePkgNeedsExposing
        m:ms -> return (NE.List m ms)



-- BUILD PROJECTS


buildExposed :: File.Writer R.PROJECT -> Reporting.Style -> R.Root -> R.Stuff -> Details.Details -> Maybe FilePath -> NE.List Module.Name -> Task ()
buildExposed writer style root stuff details maybeDocs exposed =
  let
    docsGoal = maybe Build.IgnoreDocs Build.WriteDocs maybeDocs
  in
  Task.eio Exit.MakeCannotBuild $
    Build.fromExposed writer style root stuff details docsGoal exposed


buildPaths :: File.Writer R.PROJECT -> Reporting.Style -> R.Root -> R.Stuff -> Details.Details -> NE.List FilePath -> Task Build.Artifacts
buildPaths writer style root stuff details paths =
  Task.eio Exit.MakeCannotBuild $
    Build.fromPaths writer style root stuff details paths



-- GET MAINS


getMains :: Build.Artifacts -> [Module.Name]
getMains (Build.Artifacts _ _ roots modules) =
  Maybe.mapMaybe (getMain modules) (NE.toList roots)


getMain :: [Build.Module] -> Build.Root -> Maybe Module.Name
getMain modules root =
  case root of
    Build.Inside name ->
      if any (isMain name) modules
      then Just name
      else Nothing

    Build.Outside name _ (Opt.LocalGraph maybeMain _ _) ->
      case maybeMain of
        Just _  -> Just name
        Nothing -> Nothing


isMain :: Module.Name -> Build.Module -> Bool
isMain targetName modul =
  case modul of
    Build.Fresh name _ (Opt.LocalGraph maybeMain _ _) ->
      Maybe.isJust maybeMain && name == targetName

    Build.Cached name mainIsDefined _ ->
      mainIsDefined && name == targetName



-- HAS ONE MAIN


hasOneMain :: Build.Artifacts -> Task Module.Name
hasOneMain (Build.Artifacts _ _ roots modules) =
  case roots of
    NE.List root [] -> Task.mio Exit.MakeNoMain (return $ getMain modules root)
    NE.List _ (_:_) -> Task.throw Exit.MakeMultipleFilesIntoHtml



-- GET MAINLESS


getNoMains :: Build.Artifacts -> [Module.Name]
getNoMains (Build.Artifacts _ _ roots modules) =
  Maybe.mapMaybe (getNoMain modules) (NE.toList roots)


getNoMain :: [Build.Module] -> Build.Root -> Maybe Module.Name
getNoMain modules root =
  case root of
    Build.Inside name ->
      if any (isMain name) modules
      then Nothing
      else Just name

    Build.Outside name _ (Opt.LocalGraph maybeMain _ _) ->
      case maybeMain of
        Just _  -> Nothing
        Nothing -> Just name



-- GENERATE


generate :: File.Writer R.PROJECT -> Reporting.Style -> FilePath -> B.Builder -> NE.List Module.Name -> Task ()
generate writer style target builder names =
  Task.io $
    do  Dir.createDirectoryIfMissing True (FP.takeDirectory target)
        File.writeBuilder writer target builder
        Reporting.reportGenerate style names target



-- TO BUILDER


data DesiredMode = Debug | Dev | Prod


toBuilder :: R.Stuff -> Details.Details -> DesiredMode -> Build.Artifacts -> Task B.Builder
toBuilder stuff details desiredMode artifacts =
  Task.mapError Exit.MakeBadGenerate $
    case desiredMode of
      Debug -> Generate.debug stuff details artifacts
      Dev   -> Generate.dev   stuff details artifacts
      Prod  -> Generate.prod  stuff details artifacts



-- PARSERS


reportType :: Parser ReportType
reportType =
  Parser
    { _singular = "report type"
    , _plural = "report types"
    , _parser = \string -> if string == "json" then Just Json else Nothing
    , _suggest = \_ -> return ["json"]
    , _examples = \_ -> return ["json"]
    }


output :: Parser Output
output =
  Parser
    { _singular = "output file"
    , _plural = "output files"
    , _parser = parseOutput
    , _suggest = \_ -> return []
    , _examples = \_ -> return [ "elm.js", "index.html", "x.c", "/dev/null" ]
    }


parseOutput :: String -> Maybe Output
parseOutput name
  | isDevNull name      = Just DevNull
  | hasExt ".html" name = Just (Html name)
  | hasExt ".js"   name = Just (JS name)
  | hasExt ".optc" name = Just (C name)
  | hasExt ".c"    name = Just (FicC name)
  | hasExt ".types" name = Just (Types name)
  | hasExt ".mono" name = Just (Mono name)
  | otherwise           = Nothing


docsFile :: Parser FilePath
docsFile =
  Parser
    { _singular = "json file"
    , _plural = "json files"
    , _parser = \name -> if hasExt ".json" name then Just name else Nothing
    , _suggest = \_ -> return []
    , _examples = \_ -> return ["docs.json","documentation.json"]
    }


hasExt :: String -> String -> Bool
hasExt ext path =
  FP.takeExtension path == ext && length path > length ext


isDevNull :: String -> Bool
isDevNull name =
  name == "/dev/null" || name == "NUL" || name == "$null"
