{-# LANGUAGE TemplateHaskell #-}
module Ficcus.Mono.Embed
  ( embedFiles
  )
  where


-- Ficcus: the runtime C files in `runtime/` are read at build time and become one String in the compiler.
-- The paths are relative to the package directory (where cabal runs the compiler); every file is registered
-- as a dependency, so a change of a C file rebuilds the module that embeds it.


import Language.Haskell.TH (Exp, Q, litE, runIO, stringL)
import Language.Haskell.TH.Syntax (addDependentFile)


embedFiles :: [FilePath] -> Q Exp
embedFiles paths =
  do  mapM_ addDependentFile paths
      texts <- runIO (mapM readFile paths)
      litE (stringL (concat texts))
