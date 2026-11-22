{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE TemplateHaskell #-}
module Ficcus.CorePackages
  ( CorePackage(..)
  , corePackages
  , substitute
  , writeSource
  , readSetting
  , mentionsCorePackage
  )
  where


-- Ficcus (G43, G38): package substitution in the builds to C. The list of core packages below is the table.
--
-- A project that depends on a package for which Ficcus core has a package of the same name gets the core one in a C build
-- (`--output=x.c` or `x.mono`), provided the dependency's version is inside the range that the core package declares; otherwise the
-- Elm package is used. A build to JavaScript always uses the Elm package. The core package's source ships inside the compiler (like the
-- overlay) and is written to `elm-stuff/<compiler version>/ficcus-core/<author>/<project>/src/` for the build of that package, whose
-- `elm.json` (exposed modules, dependencies) is still the Elm package's. The package is compiled under its own name, so its ids are
-- `cmditch/elm-bigint:BigInt.*` and a project's types and the package's agree. The core package may import only the overlay modules
-- (Vector, Bitwise64) and elm/core. A project turns the substitution off with `"ficcus-core-packages": false` in its elm.json
-- (the official 0.19.3 compiler ignores the unknown field).


import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import qualified System.Directory as Dir
import System.FilePath ((</>), takeDirectory)

import qualified Elm.Constraint as Con
import qualified Elm.Package as Pkg
import qualified Elm.Version as V
import qualified Json.Decode as D

import Ficcus.Mono.Embed (embedFiles)


data CorePackage =
  CorePackage
    { _name :: String                   -- `author/project`
    , _range :: Con.Constraint          -- the versions of the Elm package whose API the core package implements
    , _modules :: [(String, String)]    -- (module file name, source): the exposed modules
    }


corePackages :: [CorePackage]
corePackages =
  [ CorePackage "cmditch/elm-bigint" (Con.untilNextMajor (V.toVersion 2 0 0))
      [ ("BigInt.elm", $(embedFiles [ "core-packages/cmditch/elm-bigint/BigInt.fic" ])) ]
  ]


-- | the core package that replaces this package version in a C build, if there is one
substitute :: Pkg.Name -> V.Version -> Maybe CorePackage
substitute pkg vsn =
  case [ c | c <- corePackages, _name c == Pkg.toChars pkg, Con.satisfies (_range c) vsn ] of
    c : _ -> Just c
    [] -> Nothing


-- | write the source of the core package under `dir` (the project's elm-stuff directory) and return its `src` directory
writeSource :: FilePath -> Pkg.Name -> CorePackage -> IO FilePath
writeSource stuffDir pkg core =
  do  let src = takeDirectory stuffDir </> "ficcus-core" </> Pkg.toUrl pkg </> "src"
      Dir.createDirectoryIfMissing True src
      mapM_ (\(file, text) -> writeFile (src </> file) text) (_modules core)
      return src


-- | the project setting `"ficcus-core-packages": false` of the elm.json at this path (absent: substitution is on)
readSetting :: FilePath -> IO Bool
readSetting elmJson =
  do  exists <- Dir.doesFileExist elmJson
      if not exists then return True else
        do  bytes <- B.readFile elmJson
            result <- D.fromByteString (D.oneOf [ D.field (B8.pack "ficcus-core-packages") D.bool, pure True ]) bytes
            return (either (const True) id (result :: Either (D.Error ()) Bool))


-- | does the elm.json at this path name a package of the table (a build to C may then substitute it)?
mentionsCorePackage :: FilePath -> IO Bool
mentionsCorePackage elmJson =
  do  exists <- Dir.doesFileExist elmJson
      if not exists then return False else
        do  bytes <- B.readFile elmJson
            return (any (\c -> B8.pack ("\"" ++ _name c ++ "\"") `B.isInfixOf` bytes) corePackages)
