{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE TemplateHaskell, PatternGuards #-}
module Ficcus.Mono.Concurrent
  ( concSource, concFileName
  , concTypeNames, concOn
  , concRedirect
  , concKernels, concKernelId
  , concRuntime, concUsed, patchSched
  )
  where


-- Ficcus T1a-1 (docs/attach/T1A-NOTES.md; docs/T1-THREADING-DESIGN.md T1-D2 to T1-D5, T1-D13, T1-D14): the `Concurrent` module.
--
-- The Elm side is overlay/Concurrent.elm, written beside the Vector overlay into `elm-stuff/ficcus-overlay/` (terminal Make): a module
-- `Concurrent` of the project comes first in the source directories and wins. The overlay's types Pid, Address and Mailbox are declared
-- with one marker constructor each (never built): when the three markers are there (`concOn`), the types are references (not
-- enumerations, as the Vector) and the functions of its kernel section are the kernels `elm/core:Concurrent.<name>` (`concRedirect`).
-- The C side is runtime/fic_conc.h, emitted after runtime/fic_sched.h by a program that calls one of the kernels (`concUsed`); such a
-- program gets fic_sched.h with three patches (`patchSched`), every other program gets it unchanged (byte identity, T1-D12).


import qualified Data.List as List
import qualified Data.Map as Map

import Ficcus.Mono.Embed (embedFiles)


concSource :: String
concSource =
  $(embedFiles [ "overlay/Concurrent.elm" ])


concFileName :: FilePath
concFileName = "Concurrent.elm"


concModuleId :: String
concModuleId = "author/project:Concurrent."


-- | the built-in types and their marker constructors
concTypes :: [(String, String)]
concTypes =
  [ (concModuleId ++ "Pid", "FicConcPidBuiltin")
  , (concModuleId ++ "Address", "FicConcAddressBuiltin")
  , (concModuleId ++ "Mailbox", "FicConcMailboxBuiltin") ]


concTypeNames :: [String]
concTypeNames = map fst concTypes


-- | is the overlay's module there (every type with exactly its marker constructor)? `ctors` gives the constructor names of a union
concOn :: (u -> [String]) -> Map.Map String u -> Bool
concOn ctors unions =
  and [ maybe False (\u -> ctors u == [m]) (Map.lookup t unions) | (t, m) <- concTypes ]


-- | the kernel that a call of the overlay's function stands for
concRedirect :: (u -> [String]) -> Map.Map String u -> String -> Maybe String
concRedirect ctors unions cid =
  case List.stripPrefix concModuleId cid of
    Just n | n `elem` [ k | (k, _, _) <- concKernels ], concOn ctors unions -> Just (concKernelId n)
    _ -> Nothing


concKernelId :: String -> String
concKernelId n = "elm/core:Concurrent." ++ n


-- | name, arity, ownership signature (Ficcus.Mono.Kernel.kernelSig): every operation is a task that stores its arguments
concKernels :: [(String, Int, String)]
concKernels =
  [ ("spawnRaw", 2, "oo"), ("address", 1, "o"), ("self", 1, "o"), ("send", 2, "oo")
  , ("receive", 1, "o"), ("await", 1, "o"), ("kill", 1, "o") ]


concRuntime :: String
concRuntime =
  $(embedFiles [ "runtime/fic_conc.h" ])


-- | does the generated body call a kernel of Concurrent?
concUsed :: String -> Bool
concUsed body = "fic_conc_" `List.isInfixOf` body


-- | fic_sched.h for a program that uses Concurrent: the run queue's pick and the current process (fic_sched_enqueue), and the
-- registry's teardown first in fic_platform_teardown. Each anchor must occur exactly once.
patchSched :: String -> Either String String
patchSched text =
  do  t1 <- replaceOnce
              "    fic_ref q = fic_rq[fic_rq_head];\n    fic_rq_head = (fic_rq_head + 1) % fic_rq_cap; fic_rq_len--;\n    fic_sched_step((fic_proc *)q);\n"
              "    fic_ref q = fic_conc_pick();                                /* T1a: the pick of the seeded shuffle (fic_conc.h) */\n    fic_rq_head = (fic_rq_head + 1) % fic_rq_cap; fic_rq_len--;\n    fic_conc_cur_p = q;\n    fic_sched_step((fic_proc *)q);\n    fic_conc_cur_p = NULL;\n"
              text
      t2 <- replaceOnce
              "static FIC_UNUSED void fic_platform_teardown(void) {\n  int i;\n"
              "static FIC_UNUSED void fic_platform_teardown(void) {\n  int i;\n  fic_conc_teardown();                                              /* T1a: the processes of Concurrent */\n"
              t1
      return (header ++ t2)
  where
    header =
      "/* T1a: fic_sched.h with the hooks of runtime/fic_conc.h (Ficcus.Mono.Concurrent.patchSched) */\n"
      ++ "static void *fic_conc_cur_p;\nstatic fic_ref fic_conc_pick(void);\nstatic void fic_conc_teardown(void);\n"
    replaceOnce old new t =
      case breakOn old t of
        Just (a, b) | Nothing <- breakOn old b -> Right (a ++ new ++ b)
        _ -> Left ("internal: Concurrent: the scheduler text has not exactly one `" ++ takeWhile (/= '\n') (dropWhile (== ' ') old) ++ "`")
    breakOn pat s = go "" s
      where
        go acc r
          | pat `List.isPrefixOf` r = Just (reverse acc, drop (length pat) r)
          | otherwise = case r of { [] -> Nothing; c : r' -> go (c : acc) r' }
