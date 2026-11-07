{-# OPTIONS_GHC -Wall #-}
module Ficcus.TypesFile
  ( write
  )
  where


-- Ficcus: write the `.types` dump of one module (shared by Build for project
-- modules and Details for package modules).


import qualified Data.ByteString.Builder as BB
import System.IO (hPutStrLn, stderr)

import qualified AST.Canonical as Can
import qualified AST.Prim.Module as Module
import qualified File
import qualified Type.Dump as Dump
import qualified Type.Readout as Typed


write :: File.Writer t -> FilePath -> Module.Name -> Can.Module -> Typed.Typed -> IO ()
write writer path name canonical typed =
  do  let result = Dump.render canonical typed
      let summary =
            "-- module " ++ Module.toChars name
            ++ ": problems=" ++ show (Dump._problems result)
            ++ " instances=" ++ show (Dump._matched result)
            ++ " instance-failures=" ++ show (Dump._matchFailed result)
            ++ " defaulted=" ++ show (Dump._defaulted result)
      if Dump._problems result > 0
        then hPutStrLn stderr ("type dump of " ++ Module.toChars name ++ " has " ++ show (Dump._problems result) ++ " problem(s), see the !! lines")
        else return ()
      let equality =
            "-- equality-uses: total=" ++ show (Dump._eqUses result)
            ++ " at-function=" ++ show (length (Dump._eqFunUses result))
      let funLines = map ("-- equality-at-function: " ++) (Dump._eqFunUses result)
      File.writeBuilder writer path (BB.stringUtf8 (unlines (summary : equality : funLines ++ Dump._text result)))
