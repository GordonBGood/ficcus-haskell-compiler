{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE TemplateHaskell #-}
module Ficcus.Mono.CRuntime
  ( prelude
  )
  where


-- Ficcus: the runtime pieces that generated C needs besides `ficrt.h` (the reference counting and the
-- allocator stay in `targets/c/ficrt.h`, included first by `fic_base.h`).
-- They are real C files in `runtime/` (compiled and tested standalone by `runtime/test.sh`) and are
-- embedded here at build time, in this order, as one text emitted at the top of each generated file.
-- Strings are heap objects {header, byte length, UTF-8 bytes, NUL}; slices 1 to 3 never free them.
-- Floats print like JavaScript's Number toString.


import Ficcus.Mono.Embed (embedFiles)


prelude :: String
prelude =
  $(embedFiles
      [ "runtime/fic_base.h"
      , "runtime/fic_string.h"
      , "runtime/fic_num.h"
      , "runtime/fic_format.h"
      , "runtime/fic_debug.h"
      ])
