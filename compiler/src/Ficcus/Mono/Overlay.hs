{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE TemplateHaskell, PatternGuards #-}
module Ficcus.Mono.Overlay
  ( overlaySource
  , overlayModuleName
  , supportModuleNames
  , overlayFileName
  , overlayId
  , randomSource, randomFileName, randomOverlayPrefix
  , bitwise64Source
  , bitwise64FileName
  , sizedSources
  , sortSource, sortListSource, sortFileName
  , vectorSource, vectorFileName, vectorModuleId, vectorTypeName, vectorMarker
  , parserSource
  , parserFileName
  , jsonSource, jsonFileName
  , bytesSource, bytesFileName
  , regexSource, regexFileName
  )
  where


-- Ficcus, stage (iii) slice 4b: the overlay of elm/core (STAGE3-PLAN, "overlay").
--
-- Some polymorphic functions of elm/core have no Elm body (`Elm.Kernel.List.map2`). Instead of writing a C
-- function per element class, they are written once in Elm (`overlay/FicOverlay.elm`, embedded here) and
-- cloned per class by the specializer like any other definition. The module is written into the project's
-- `elm-stuff/ficcus-overlay/` and compiled as an extra root module of every `.c` and `.mono` build, and the
-- specializer redirects the kernel id to the definition below.


import Data.Char (toUpper)
import qualified Data.List as List

import Ficcus.Mono.Embed (embedFiles)


overlaySource :: String
overlaySource =
  $(embedFiles [ "overlay/FicOverlay.elm" ])


overlayModuleName :: String
overlayModuleName = "FicOverlay"


-- | the modules that are not part of the project in the listings (`x.mono`, `x.types`): the overlay of elm/core and the Elm parts of
-- the Json and Bytes kernels, which are compiled into every project that lists the package
supportModuleNames :: [String]
supportModuleNames = [overlayModuleName, "FicOverlaySort", "FicOverlayJson", "FicOverlayBytes", "FicOverlayRegex"]


overlayFileName :: FilePath
overlayFileName = "FicOverlay.elm"


-- | the id of the overlay definition that replaces a kernel function (the project's package is the
-- application's dummy package name)
overlayId :: String -> Maybe String
overlayId cid =
  case lookup cid table of
    Just name -> Just ("author/project:" ++ overlayModuleName ++ "." ++ name)
    Nothing ->
      case cid of
        "elm/core:List.sort" -> Just ("author/project:FicOverlaySort.listSort")
        "elm/core:List.sortBy" -> Just ("author/project:FicOverlaySort.listSortBy")
        "elm/core:List.sortWith" -> Just ("author/project:FicOverlaySort.listSortWith")
        "elm/parser:Parser.Advanced.multiComment" -> Just "author/project:FicOverlayParser.multiComment"
        "elm/random:Random.float" -> Just "author/project:FicOverlayRandom.float"
        _ | Just n <- List.stripPrefix "elm/json:Json.Encode." cid, n `elem` ["list", "array", "set", "object", "dict"] ->
              Just ("author/project:FicOverlayJson.encode" ++ capital n)
          | Just n <- List.stripPrefix "elm/json:Json.Decode." cid, n `elem` ["array", "keyValuePairs", "map3", "map4", "map5", "map6", "map7", "map8"] ->
              Just ("author/project:FicOverlayJson." ++ n)
          | Just n <- List.stripPrefix "elm/bytes:Bytes.Decode." cid
          , n `elem` [ "decode", "signedInt8", "signedInt16", "signedInt32", "unsignedInt8", "unsignedInt16", "unsignedInt32", "float32", "float64"
                     , "bytes", "string", "map", "map2", "map3", "map4", "map5", "andThen", "succeed", "fail", "loop" ] ->
              Just ("author/project:FicOverlayBytes." ++ n)
          | Just n <- List.stripPrefix "elm/regex:Regex." cid
          , n `elem` [ "fromStringWith", "never", "contains", "find", "findAtMost", "replace", "replaceAtMost", "split", "splitAtMost" ] ->
              Just ("author/project:FicOverlayRegex." ++ n)
        _ -> Nothing
  where
    table =
      [ ("elm/core:List.map2", "listMap2"), ("elm/core:List.map3", "listMap3")
      , ("elm/core:List.map4", "listMap4"), ("elm/core:List.map5", "listMap5")
      , ("elm/core:List.indexedMap", "listIndexedMap")
      ]
    -- the module of the parser overlay is not the same: see below
    capital n = case n of { c : rest -> toUpper c : rest; [] -> [] }


-- the 64 bit Bitwise module (overlay/Bitwise64.elm): written beside FicOverlay.elm, its functions are kernel functions
bitwise64Source :: String
bitwise64Source =
  $(embedFiles [ "overlay/Bitwise64.elm" ])


bitwise64FileName :: FilePath
bitwise64FileName = "Bitwise64.elm"


-- the Vector module (overlay/Vector.elm; V1, docs/STAGE4-V1.md): written beside FicOverlay.elm like Bitwise64; a project module of the
-- same name comes first in the source directories and wins
vectorSource :: String
vectorSource =
  $(embedFiles [ "overlay/Vector.elm" ])


vectorFileName :: FilePath
vectorFileName = "Vector.elm"


-- | the id prefix of its definitions, the name of its type, and the constructor that tells the overlay's type from a type `Vector` in
-- a module `Vector` of the project
vectorModuleId, vectorTypeName, vectorMarker :: String
vectorModuleId = "author/project:Vector."
vectorTypeName = "author/project:Vector.Vector"
vectorMarker = "FicVectorBuiltin"


-- the elm/parser overlay (overlay/FicOverlayParser.elm): compiled only into projects that depend on elm/parser
parserSource :: String
parserSource =
  $(embedFiles [ "overlay/FicOverlayParser.elm" ])


parserFileName :: FilePath
parserFileName = "FicOverlayParser.elm"


-- the elm/json overlay (overlay/FicOverlayJson.elm): compiled only into projects that depend directly on elm/json
jsonSource :: String
jsonSource =
  $(embedFiles [ "overlay/FicOverlayJson.elm" ])


jsonFileName :: FilePath
jsonFileName = "FicOverlayJson.elm"


-- the elm/bytes overlay (overlay/FicOverlayBytes.elm): compiled only into projects that depend directly on elm/bytes
bytesSource :: String
bytesSource =
  $(embedFiles [ "overlay/FicOverlayBytes.elm" ])


bytesFileName :: FilePath
bytesFileName = "FicOverlayBytes.elm"


-- the elm/regex overlay (overlay/FicOverlayRegex.elm): compiled only into projects that depend directly on elm/regex
regexSource :: String
regexSource =
  $(embedFiles [ "overlay/FicOverlayRegex.elm" ])


regexFileName :: FilePath
regexFileName = "FicOverlayRegex.elm"


-- the elm/random overlay (overlay/FicOverlayRandom.elm): compiled only into projects that depend on elm/random
randomSource :: String
randomSource =
  $(embedFiles [ "overlay/FicOverlayRandom.elm" ])


randomFileName :: FilePath
randomFileName = "FicOverlayRandom.elm"


-- | the module whose own calls are not redirected (the overlay of `Random.float` calls `Random.float`)
randomOverlayPrefix :: String
randomOverlayPrefix = "author/project:FicOverlayRandom."


-- | SIZED (docs/SIZED-PLAN.md): the modules of the sized integers and Float32 (overlay/Int8.elm ... , generated by ficcus-tools/gen_sized.py),
-- written beside FicOverlay.elm like Bitwise64: a module of the same name in the project or in a package comes first and wins
sizedSources :: [(FilePath, String)]
sizedSources =
  [ ("Int8.elm", $(embedFiles [ "overlay/Int8.elm" ]))
  , ("Int16.elm", $(embedFiles [ "overlay/Int16.elm" ]))
  , ("Int32.elm", $(embedFiles [ "overlay/Int32.elm" ]))
  , ("Int64.elm", $(embedFiles [ "overlay/Int64.elm" ]))
  , ("Word8.elm", $(embedFiles [ "overlay/Word8.elm" ]))
  , ("Word16.elm", $(embedFiles [ "overlay/Word16.elm" ]))
  , ("Word32.elm", $(embedFiles [ "overlay/Word32.elm" ]))
  , ("Word64.elm", $(embedFiles [ "overlay/Word64.elm" ]))
  , ("Float32.elm", $(embedFiles [ "overlay/Float32.elm" ]))
  , ("Float64.elm", $(embedFiles [ "overlay/Float64.elm" ]))
  ]


-- the sorts (overlay/FicOverlaySort.elm on the Vector; overlay/FicOverlaySortList.elm on lists, for a project with a module `Vector` of its own)
sortSource, sortListSource :: String
sortSource = $(embedFiles [ "overlay/FicOverlaySort.elm" ])
sortListSource = $(embedFiles [ "overlay/FicOverlaySortList.elm" ])


sortFileName :: FilePath
sortFileName = "FicOverlaySort.elm"
