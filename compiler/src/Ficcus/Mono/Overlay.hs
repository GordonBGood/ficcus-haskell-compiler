{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE TemplateHaskell #-}
module Ficcus.Mono.Overlay
  ( overlaySource
  , overlayModuleName
  , overlayFileName
  , overlayId
  )
  where


-- Ficcus, stage (iii) slice 4b: the overlay of elm/core (STAGE3-PLAN, "overlay").
--
-- Some polymorphic functions of elm/core have no Elm body (`Elm.Kernel.List.map2`). Instead of writing a C
-- function per element class, they are written once in Elm (`overlay/FicOverlay.elm`, embedded here) and
-- cloned per class by the specializer like any other definition. The module is written into the project's
-- `elm-stuff/ficcus-overlay/` and compiled as an extra root module of every `.c` and `.mono` build, and the
-- specializer redirects the kernel id to the definition below.


import Ficcus.Mono.Embed (embedFiles)


overlaySource :: String
overlaySource =
  $(embedFiles [ "overlay/FicOverlay.elm" ])


overlayModuleName :: String
overlayModuleName = "FicOverlay"


overlayFileName :: FilePath
overlayFileName = "FicOverlay.elm"


-- | the id of the overlay definition that replaces a kernel function (the project's package is the
-- application's dummy package name)
overlayId :: String -> Maybe String
overlayId cid =
  case lookup cid table of
    Just name -> Just ("author/project:" ++ overlayModuleName ++ "." ++ name)
    Nothing -> Nothing
  where
    table =
      [ ("elm/core:List.map2", "listMap2"), ("elm/core:List.map3", "listMap3")
      , ("elm/core:List.map4", "listMap4"), ("elm/core:List.map5", "listMap5")
      , ("elm/core:List.indexedMap", "listIndexedMap")
      , ("elm/core:List.sortBy", "listSortBy"), ("elm/core:List.sortWith", "listSortWith")
      ]
