# T5: rule based translation of the compiler to Ficus

Design note, read only. Branch `design/t5` from `ficcus` `af71a00e`, 27 Nov 2026. Addendum (section 9, branch `design/t5-addendum`): the user's Elm in Elm port; decisions 1 and 2 revised.
Inputs: decisions rev 179 (T5), 180/181 (25 Nov parser order, P2, P3), the 25 Nov tail call note (T2 to T4), G21, G30, G67, rev 700 (FFI slices), rev 702/707 (plan, estimate). The counts below come from grep over the sources at `af71a00e`; they are approximate (regex counts, not parses) and the translator's survey mode (section 4) replaces them with exact figures.

## 1. Survey of the Haskell sources

Scope: `compiler/src` (165 modules, 60,310 lines), `builder/src` (18, 8,052), `terminal/src` + `terminal/impl` (19, 5,593), `src/utils` (14, 5,535). **Total 216 modules, 79,490 lines, 3,894 top level signatures.** `worker/` (7, 1,134) is outside the cabal sources. Largest groups: `Ficus/*` 14,281 (`CGen` 3,655, `Spec` 2,187), `Reporting` 13,062, `Type` 7,973, `Parse` 4,975, `Canonicalize` 4,394, `AST` 3,771, `Elm` 3,455, `Generate` 3,026.

| Construct | Files | Hits | Translation impact |
|---|---|---|---|
| `data` / `newtype` declarations | 148 / 43 | 513 / 60 | mechanical (R2, R3) |
| record fields declared; record update `x { f = }` | 86; 25 | 674; 260 | mechanical (R3, R4); no `RecordWildCards`, no `NamedFieldPuns` |
| `where` | 216 | 776 | R7, the main laziness hazard |
| guards (incl. 35 files with `PatternGuards`) | 134 | 2,054 | R6 |
| `case ... of` | 188 | 2,892 | direct |
| list comprehensions | ~100 | ~453 | R20 |
| `class` declared | 1 | 1 | `Fork.Context` (kernel) |
| `instance` | 30 | 89 | Eq 19, Ord 17, Functor 16, Applicative 12, Monad 10, Fork.Context 4, Show 2, Exception 3, others 6 |
| `deriving` | 41 | 75 | Eq 64, Ord 29, Show 28, Enum 1, Bounded 1 (R17) |
| constraints `=>`; `forall` | 42; 14 | 413; 16 | R18; rank 2 removed in Stage A |
| `do` | 128 | ~1,984 | R9 |
| `<$>`/`fmap`; `<*>`/`pure`; `>>=`/`>>` | 97; 61; 68 | 536; 296; 325 | R10 |
| `mapM`/`traverse`/`foldM`/`when`/... | 103 | 875 | R11 |
| bang patterns; `seq`/`$!` | 46; 8 | 494; 20 | dropped (R19) |
| operator sections; ` . ` composition | 24; 77 | 53; 274 | R8 |
| primed names `x'` | | 216 distinct | R1 |
| `div`/`mod`/`rem` | | 41/22/14 | R14 (semantics differ) |
| tuples of 4 or more | 0 | 0 | nothing to do |
| `unsafePerformIO` | 18 | 65 | almost all `FICUS_NO_*` environment flags (Stage A3) |
| `IORef` | 8 | 97 | `Type.UnionFind`, `Solve`, `Recorder`, `Readout`, `Members`; `Ficus.Flags`, `Mono.Facts`, `Mono.Modules` |
| `ST`/`STRef`/`MutableByteArray` | 14 | ~40 | `Data.Utf8`, `String`, `Bytes`, `Buffer`, `Array`, `Graph`, `Json.String`, `Parse.Variable`, `Optimize.Names`, ... (kernel) |
| `MVar`; `forkIO`; STM | 6; 11; 0 | 91; 16; 0 | `Build`, `Elm.Details`, `Generate`, `File`, `Reporting`, `ThreadSafe.Fork` |
| exceptions (`catch`, `try`, `bracket`) | 23 | 103 | IO kernel only |
| `Data.Map(.Strict)` | 113 | 1,830 uses, 86 distinct functions | R12 (shim) |
| `Data.Set`; `Data.List`; `Data.IntMap`; `Data.Array` | 44; 94; 3; 2 | 515; 438 | R12, library |
| `ByteString`; `Data.Text` | 51; 0 | 91; 0 | kernel |
| `System.IO/Directory/FilePath/Process/Exit/Environment` | 47 | 100 | IO kernel (section 7) |
| HTTP/network | 13 | 22 | out of the bootstrap scope |
| `Control.Monad.State.Strict`/`StateT` | 13 | | `Ficus.Mono.*` passes, `Canonicalize.Kind`, `Selectors`, `Type.Dump`, `Repl` (R22) |
| `MagicHash` (`Addr#`, `Int#`, `I#`, `indexWord8OffAddr#`) | 59 | ~1,360 | 11 `Parse.*`, 6 `AST.Prim`, 6 `Elm`, 13 `src/utils`, 6 others |
| `INLINE`/`SPECIALIZE`/`UNPACK` pragmas | 65 | 460 | dropped |
| quasiquotes `[N.ascii\|..\|]`, `[keyword\|..\|]`, `[fsm\|..\|]`, `[table\|..\|]` | ~80 | ~440 | R13; `fsm` and `table` (Literals) need a look |
| `$(embedFile ...)` | 4 | | `Mono.Concurrent`, `CRuntime`, `Overlay`, `CorePackages`: a generated literal module |
| laziness: `[0 ..]`, `iterate`, `repeat`; `fix`/`mdo`/`~` | ~25; 0 | | R20; **no knot tying found** |
| module cycles (`.hs-boot`) | 0 | | none |
| mutual recursion groups | | | not countable by grep; the survey mode computes SCCs (expected large ones: `Parse.Expression`, `Canonicalize.Expression`, `Type.Constrain.Expression`, `Optimize.Expression`, `Ficus.Mono.*`) |

**LANGUAGE pragmas** (files): OverloadedStrings 76, MagicHash 58, BangPatterns 48, ExtendedLiterals 46, PatternGuards 35, TemplateHaskell 31, QuasiQuotes 25, UnboxedTuples 14, Rank2Types 12, EmptyDataDecls 6, CPP 5, GADTs 4, UnliftedDatatypes 3, TemplateHaskellQuotes 3, FlexibleInstances 3, MultiWayIf 2, ForeignFunctionInterface 2, BinaryLiterals 2, PolyKinds, PatternSynonyms, KindSignatures, FlexibleContexts, DoAndIfThenElse 1 each.

**Monads, by top level signatures that mention them:** `IO` 446 (73 files); `Encoder`/`Builder` 188 (43); `Decoder` (Json and Bytes) 175 (33); `Parser` 219 (30); `Result` 122 (19); `Task` 72 (9); `State` 53 (13); `Tracker` 43 (4); `ST s` 7 (2). Six of these are **rank 2 continuation passing newtypes**: `Parse.Primitives.Parser` (with `ForeignPtrContents` and `Addr#`), `Reporting.Result`, `Reporting.Task`, `Json.Decode.Decoder`, `Bytes.Decode.Decoder`, `Optimize.Names.Tracker`. Ficus is rank 1, so they cannot be translated as written.

**Reading.** The bulk is first order code over algebraic data, `case`, guards and `where`: mechanical. Type classes are nearly absent (one class); there are the monad instances and derived or hand written `Eq`/`Ord`/`Show`. The hard parts are concentrated: the CPS monads, the `Addr#` byte code, IO and concurrency in `builder/`, the mutable union find, and the `Data.Map` API breadth.

## 2. Target subset and Stage A

**Target Ficus subset** (what the translator emits): Elm 0.19 syntax; custom types and records; `let`/`case`/`if`; `Vector`, sized integers (`Word8`, `Word16`, `Int32`), `Dict`/`Set` with derived `compare` keys (A4b); attached members and constrained type variables (rev 128, A5) for `map`, `andThen`, `succeed`, `map2`, `compare`, `toString`; `derive`; `Task` and `extern`/`extern task` (FFI-a to FFI-e) in kernel modules only. Not used: `Debug` except `Debug.todo` for `crash`, ports, `Cmd`/`Sub`, any HKT or rank 2 type.

**Stage A**: rewrite the Haskell source towards that subset, in Haskell, on `ficcus`, each step gated by the existing gates (`gates.sh`: elmdiff 1175 SAME, typed corpus, types matrix, runtime, attach, JS identity) plus a compile time measurement.

| Step | Change | Why in Haskell first |
|---|---|---|
| A1 | de-CPS the six rank 2 newtypes into first order step types with the same API (`Result` first, then `Parser`, `Task`, `Tracker`, the two `Decoder`s). Example: `newtype Parser x a = Parser (State -> PStep x a)`, `data PStep x a = Cok a State \| Eok a State \| Cerr Row Col (Row -> Col -> x) \| Eerr Row Col (Row -> Col -> x)` | consumers (`do` blocks in 30 `Parse.*` files) do not change; the gates prove the error messages and ASTs equal; the translator then only needs rule R9 |
| A2 | confine `Addr#`/`I#`/`ForeignPtr` to the kernel modules (`AST.Prim.Name`, `Data.Utf8`, `String`, `Bytes*`, `Buffer`, `Literals`, `Parse.Primitives`); the ~20 other files get API calls | the kernel is hand written once in Ficus; everything else stays translatable |
| A3 | environment flags: one `Ficus.Flags` lookup per flag (already mostly so) | becomes one `extern` with the FFI-D4 purity promise (the environment is constant per run) |
| A4 | union find on a persistent store (G21): `Type.UnionFind` over an `IntMap`/array state threaded through `Solve` | the solver is the most delicate code; the types matrix and typed corpus gate it in Haskell, where failures are debuggable |
| A5 | a sequential build path in `Build`/`Details`/`Generate` (no `forkIO`/`MVar` when `-j1`) | the self hosted compiler starts sequential (T1 later); the path is gated by the same tests |
| A6 | recursion depth: run the gates under `+RTS -K256k` (needs `-rtsopts` in a test build); rewrite into state machines (`Step`/`loop`) where depth grows with the input | GHC hides deep recursion on its growable stack; the C stack does not (T3) |
| A7 | rewrites the translator flags as UNMAPPED and that are cheaper to fix in source than by a rule (refutable `<-` binds, rare `where` sharing across guards) | keeps the rule set small |

**Why safer than translating the hard constructs:** a Stage A change is tested at once by the whole existing suite, and a failure is debugged where the code was written. A CPS parser or mutable solver translated directly can only be tested end to end, with two unknowns at once (the rule and the Ficus compiler). **Cost:** A1 may slow the Haskell compiler (Evan chose CPS for speed), and Stage A diverges from upstream; both are bounded by keeping A1 to the primitive modules with unchanged APIs and a compile time limit (decision 2).

## 3. Translation rules

Each rule is a function in the rule engine with this number. An UNMAPPED case is reported, never guessed.

| # | Haskell | Ficus | Note |
|---|---|---|---|
| R1 | `module Parse.Number (number, Number(..)) where`; `import qualified Data.Map as Map`; `go'` | `module Parse.Number exposing (number, Number(..))`; `import Map`; `go_1` | names: primes, Elm keywords (`port`, `alias`, `exposing`, `effect`, `as`) get a suffix; a fixed table, collisions reported |
| R2 | `newtype ZeroBased = ZeroBased Int` | `type ZeroBased = ZeroBased Int` | the Unbox pass removes the box; `type alias` would lose the type distinction |
| R3 | `data Module = Module { _name :: Name, _decls :: [Decl] }` ; `_name m` | `type alias Module = { name : Name, decls : List Decl }` ; `m.name`; `Module a b` → `{ name = a, decls = b }` | single constructor record data only; multi constructor records → constructor with a record argument |
| R4 | `m { _decls = ds }` | `{ m \| decls = ds }` | |
| R5 | `f [] y = a; f (x:xs) y = b` | `f p1 y = case p1 of [] -> a; x :: xs -> b` | several argument patterns → `case (p1, p2) of` |
| R6 | `f x \| x < 0 = a \| otherwise = b`; `\| Just v <- lookup k m = e` | `if x < 0 then a else b`; `case lookup k m of Just v -> e; _ -> <next>` | fall through to the next equation → a local `next` function; reported when it repeats code |
| R7 | `f x = g y z where y = h x; z = expensive x` | `let y = h x in g y (let z = expensive x in z)` (float in to the narrowest scope that uses it) | Haskell evaluates `where` bindings only when used; Ficus is strict, so a binding used in one branch must move into that branch (cost, and `error` bindings) |
| R8 | `f . g`, `f $ x`, `(+ 1)`, `` a `elem` b `` | `f << g`, `f (x)`, `\v -> v + 1`, `List.member a b` | operator table; user defined operators (7 `infix` declarations) → named functions |
| R9 | `do { x <- p; spaces; pure (Num x) }` at type `Parser E a` | `p \|> Parser.andThen (\x -> spaces \|> Parser.andThen (\_ -> Parser.succeed (Num x)))` | the monad comes from the type of the `do` node (section 4); `let` statement → `let ... in`; refutable pattern bind → UNMAPPED |
| R10 | `f <$> a <*> b`; `fmap f m`; `a *> b` | `M.map2 f a b`; `M.map f m`; `M.andThen (\_ -> b) a` | `map3` to `map7` beyond; longer chains → `andMap` |
| R11 | `traverse f xs`, `mapM_ g xs`, `when c m`, `foldM s z xs` | `M.traverse f xs`, `M.forEach g xs`, `if c then m else M.succeed ()`, `M.foldl s z xs` | per monad library members, written once per monad type in the kernel library |
| R12 | `Map.findWithDefault d k m`, `Map.Map k v`, `Set.Set a` | `Map.findWithDefault d k m`, `Map k v`, `Set a` | a `Map` shim over `Dict` with all 86 functions used (incl. `merge` tactics) and Haskell's argument orders; keys need derived `compare` |
| R13 | `[N.ascii\|main\|]`, `[keyword\|type\|]` | `Name.fromChars "main"` (a literal if Name is `String`), `Keyword.keyword "type"` | `fsm` and `table` quasiquotes: hand translated kernel |
| R14 | `div a b`, `mod a b`, `quot a b`, `rem a b`, `fromIntegral (w :: Word16) :: Int` | `floorDiv a b`, `modBy b a`, `a // b`, `remainderBy b a`, `Word16.toInt w` | Haskell `div` floors, Elm `//` truncates; conversions chosen by the HIE types |
| R15 | `Char.ord c`, `Char.isDigit c` | `Char.toCode c`, `Char.isDigit c` | Elm Char quirks (decisions file) checked by the harness |
| R16 | `show n` at `Int`; `show x` at a derived Show type | `String.fromInt n`; `X.toString x` | derived `toString` (A4c) must print what GHC's `show` prints where the text reaches output; otherwise UNMAPPED |
| R17 | `deriving (Eq, Ord)`; hand written `instance Ord Name where compare = ...` | `derive (compare)`; member `compare` attached to `Name` | `Eq` needs nothing (structural `==`); a hand `Eq` that is not structural → UNMAPPED |
| R18 | `(Ord k) => Map k v -> ...`; `forall a.` | constraint dropped or written as a constrained variable (A5 infers it) | rank 2 → UNMAPPED (Stage A1 removed them) |
| R19 | `!x`, `seq`, `$!`, `{-# UNPACK #-}`, `{-# INLINE #-}` | dropped | Ficus is strict |
| R20 | `zip [0 ..] xs`; `[ f x \| x <- xs, p x ]` | `List.indexedMap Tuple.pair xs`; `List.filterMap (\x -> if p x then Just (f x) else Nothing) xs` | other infinite lists → UNMAPPED |
| R21 | `Either e a`, `Left`, `Right`; `maybe d f m`; `fromMaybe d m` | `Result e a`, `Err`, `Ok`; `Maybe.withDefault d (Maybe.map f m)`; `Maybe.withDefault d m` | the user's earlier rule |
| R22 | `State s a`, `gets f`, `modify g` | `State s a` (library type `s -> (a, s)` with members), `State.gets f`, `State.modify g` | do blocks by R9 |
| R23 | `IO a`; `readFile p`; `crash msg` | `Task Error a`; `File.read p`; `Crash.crash msg` (`Debug.todo`) | IO actions only from the IO kernel table; `catch`/`try`/`bracket` outside the kernel → UNMAPPED |
| R24 | `IORef`, `STRef`, `MVar`, `unsafePerformIO` outside the kernel | UNMAPPED | Stage A removes them |
| R25 | `instance Functor/Applicative/Monad Parser` | members `map`, `succeed`, `andThen`, `map2` attached to `Parser` | static dispatch, no emulation layer (rev 179) |
| R26 | local signatures in `where`/`let` | kept as `let` annotations | `ScopedTypeVariables` variables renamed consistently |

## 4. Translator architecture (Stage B, in Haskell)

**Place:** `ficus-tools/t5/`, its own cabal project (not in `elm.cabal`), so the compiler build and `cabal.project.freeze` are untouched. One executable, `t5`, with modes `survey`, `translate`, `harness`.

**Front end.** The `ghc` 9.10.3 package is in the global package database, so no download: parse each module with the GHC parser (`ParsedSource`, with comments and positions), and read **types from HIE files**: a build with `-fwrite-ide-info -hiedir <dir>` (a `cabal.project.local` flag) records the type of every expression span. That decides R9 to R11, R14, R16 and the overloaded names (`fmap`, `<>`, `traverse`, `show`, `fromIntegral`, literals) without a type checker of our own. Taking the monad from the enclosing signature fails for local unannotated `do` blocks, so it is only a fallback. `ghc-lib-parser` only if the `ghc` package proves awkward.

**Middle.** Normalize (equations to `case`, guards, `where` float in, sections), then the **rule engine**: an ordered list of `(RuleId, Ctx -> HsNode -> Maybe FicNode)`; the first match wins; every node must be matched. **Unmapped constructs** produce `UNMAPPED R? <construct> at File.hs:line:col` in `t5-report.txt` and an output that fails to compile on purpose (`Debug.todo "T5 UNMAPPED ..."` plus a marker), never a guess. The name table (`t5-names.tsv`, Haskell qualified name → Ficus name, kernel or library) is data, reviewed by the user.

**Back end.** A small Ficus AST and a deterministic printer in `elm-format` layout; optional `-- R9` provenance comments (off by default). **Re-runnable:** generated files are never edited by hand; a hand version of one function goes into `t5-overrides/<Module>.fic` by name, and the translator splices it in and lists it in the report, so a rerun after an upstream merge keeps it and shows when its Haskell source changed (hash in the report).

**Survey mode** prints section 1's table per module, the SCCs of the call graph and of the tail call graph (input for T2), and the UNMAPPED nodes: the progress metric.

**Golden references** (superseded by section 9.4). The Elm in Elm ports (Fir, 20,741 lines; `pithub/elm-compiler-in-elm`) are not in this workspace; the user places them under `reference/`. For modules unchanged since 0.19.1, output is compared with them up to naming (a reading aid, not a gate).

## 5. Per module differential harness

The user's method, automated: every exposed function of a translated module is called on generated cases, in Haskell and in Ficus, and the printed results must be equal byte for byte.

1. **Generation (Haskell).** `t5 harness M` emits a driver `HarnessM.hs` compiled against the elm library modules (not GHCi, which is slow at this size). Generators: built in ones (Int, Char, String, Name, List, Maybe, Map, tuples) and ones derived from `data` declarations. **Edge limits first, then random with a fixed seed:** `Int` 0, 1, -1, min, max, 2^31 and 2^32 boundaries; empty and one element lists, maps and strings; UTF-8 of 1 to 4 bytes, a lone `\r`, tabs; names equal to keywords; positions at end of input; depth 10^5 (only under T3's small stack mode). Function arguments come from a fixed named set written in both languages (`identity`, `negate`, a constant, a failing parser).
2. **Storage.** The driver writes, per function, the cases as a **Ficus source module** `ficus-tests/t5/<M>/Cases.fic` (literals, so Ficus needs no decoder) and the Haskell results as `expected.txt`, both committed, together with the hash of the Haskell source. Cases are regenerated only when that hash changes.
3. **Ficus side.** A generated `Main.fic` imports the translated module and the cases, applies each function and prints with the same **canonical printer** (generated per type for both languages: constructor names, records with sorted fields, strings escaped, `Float` in JavaScript form; GHC's `show` is not used).
4. **Crashes.** Haskell: `try (evaluate (force r))` prints `CRASH <message>`; Ficus: `Crash.crash` prints the same line and the driver continues by running each case in a child process when a crash is expected, or comparing only the crash category.
5. **IO functions.** Run in a fresh temporary directory with a fixture tree; the result and a listing of the tree afterwards (names, sizes, hashes) are compared.
6. **Failure message.** `M.f case 17/200 (edge: empty input): input <canonical> | haskell <...> | ficus <...> | first difference at byte 41`. A run summary per module: functions, cases, equal, differing, crashed, UNMAPPED.
7. **Whole compiler gate** (later): the translated compiler against the Haskell compiler on the elmdiff corpus and the typed corpus, ASTs and error reports included (P2's gate).

## 6. Pilot modules, order and rate

| Pilot | Modules (lines) | Exercises |
|---|---|---|
| Pure | `Data.Index` 140, `Data.NonEmptyList` 90, `Data.OneOrMore` 98, `Data.Bag` 109, then `Optimize.DecisionTree` 485 | R1 to R8, R17, R20; the AST modules it imports are emitted in a **types only** mode first |
| Result | `Reporting.Result` 133 (after A1), `Canonicalize.Pattern` 171, `Canonicalize.Type` 170 | R9 to R11, R25, the `Result` library members |
| Parser | `Parse.Primitives` 470 (after A1; hand kernel over `Vector Word8` and an `Int` position, rev 181), `Parse.Keyword` 47, `Parse.Number` 292, then `Parse.Pattern` 330 | the `Parser` members, R13, error text equality, `Step` loops (T4) |
| IO | `builder/src/File.hs` 353 | the IO kernel, `Task`, binary file reads and writes, locking |

About 2,900 lines in all. **Order of the rest:** leaves up the import graph: `Data.*`, `AST.Prim.*` (kernel), `Reporting.Annotation`, `AST.*` (data and encoders), `Reporting.Doc` and `Reporting.Error.*` (13,062 lines of mostly pure text, very mechanical), `Parse.*`, `Canonicalize.*`, `Type.*` (after A4), `Nitpick`, `Optimize`, `Ficus.Mono.*` (14,281, pure passes on `State`), `Generate.*`, `Json`, then `builder/` and `terminal/` (make only).
**Rate (to be replaced by the pilot's measurement):** once the rules settle, one session translates and tests about 1,500 to 3,000 lines (3 to 10 modules of the pure kind; 1 or 2 of `Type.Solve` or `CGen` size). About 75,000 lines of non kernel code gives **30 to 50 sessions**, plus 5 to 8 for kernels and shims; this is within the 4 to 10 week guess of rev 707. The pilot decides the figure.

## 7. Dependencies and the I/O model

| Item | Needed for | When |
|---|---|---|
| T3 small stack mode | the harness's depth cases; every pilot | before the Parser pilot |
| T4 `Step`/`loop` | Stage A6 state machines; `Parser` loops (`chompWhile`, `many`) | before the Parser pilot |
| T2 tail SCC | mutual tail recursion in `Parse.*`, `Type.*`, `Mono.*` running in constant stack on large inputs | before the whole compiler runs on the corpus; not for the pilot |
| FFI-a (syntax, strings), FFI-b (vectors), FFI-e (`extern task`) | the IO kernel and `File` pilot | before the IO pilot |
| FFI-c (handles) | directory walking, file locks, processes | before `builder/` |
| FFI-d (GMP) | not needed | |
| G30 `Vector Word8` at natural width | parser input memory (8 bytes per byte now) | before profiling and the bootstrap; the pilot runs without it |
| E3 (ports) | not needed (the compiler is a command line program) | |
| A4b/A4c derive, A5 constraints | R16, R17, R18, `Map` keys | already merged or queued |

**I/O model of the self hosted compiler:** a command line program whose `main` runs one `Task` chain (the Haskell `IO` code becomes `Task` by R23), on the main thread, sequentially (Stage A5). The kernel needs: binary file read and write, file exists, modification time, create directory, list directory, remove file, current directory, arguments, environment, exit code, stdout and stderr (with colour when a terminal), process spawning with exit code and captured output (the C compiler), and a file lock. All are `extern task` in the blocking form (FFI-D6). Out of the bootstrap scope (decision 6): HTTP, zip, SHA-1 (`install`, `bump`, `diff`, `publish`), `reactor` and `repl`; the package cache is filled by the Haskell compiler.

## 8. Risks and what only the pilot can decide

- **A1 performance:** measured on the `Result` step first.
- **HIE coverage:** that every `do` node and overloaded name has a usable type is believed, not verified (session 2).
- **Strictness:** `where` bindings that are expensive or `error` in unused branches; R7 handles the syntactic cases, the harness finds the rest only if a case reaches them.
- **Speed of translated code:** `andThen` chains allocate closures; H16 should fuse known combinators; deep chains depend on T2/T4. Unknown until the Parser pilot is profiled (P2 trigger above 10 to 15 percent).
- **`Map` shim fidelity** (`merge` tactics, fold orders): its own harness.
- **Text output:** `Reporting.Doc` and error messages byte for byte; Fir showed it is possible for parse errors.
- **Upstream drift:** translator reruns are cheap, Stage A rebases are not.
- **Rate:** only the pilot gives sessions per 1,000 lines and the UNMAPPED share.

## Decisions to approve (recommendation order)

1. **Stage A on `ficcus`** (revised, section 9), gated by the full gates: A1 on `Reporting.Result` with the user's port's type and API and Haskell's error accumulation; then A4, the union find on the port's `STRef` design; then A1 on `Parse.Primitives` (`Cok/Eok/Cerr/Eerr`), `Tracker`, `Task`, the two `Decoder`s.
2. **Compile time limit:** at most 10 percent slower on the typed corpus per A1 or A4 step; otherwise the step stays on its branch for a rethink. If A4 exceeds it, Haskell keeps `IORef` and the Ficus union find becomes a kernel module over a mutable vector.
3. **Front end:** the `ghc` 9.10.3 package parser plus HIE types; the translator in `ficus-tools/t5/` as its own cabal project.
4. **No hand edits of generated files;** per function overrides with source hashes; UNMAPPED fails the build.
5. **Kernel list, hand written in Ficus:** `AST.Prim.Name`, `Data.Utf8`, `String`, `Bytes.*`, `Buffer`, `Literals` (`fsm`, `table`), `Parse.Primitives` core, `Map`/`Set` shim, `Crash`, `Flags`, `File` and the IO table, `ThreadSafe.Fork` (sequential).
6. **Bootstrap scope:** `make` only (C and JS output); HTTP commands, `reactor` and `repl` later or never.
7. **`Name` is a Ficus `String`** (UTF-8 already), revisited only if profiling says so.
8. **Representation rules R2 and R3** (newtype → one constructor custom type; single constructor record data → record alias) and the arithmetic rule R14.
9. **Harness:** compiled Haskell drivers, cases committed as Ficus literal modules, generated canonical printers, edge cases first.
10. **Pilot order:** Pure, Result, Parser, IO; the rate figure from the pilot replaces section 6's estimate.

## Session 1 (Sonnet): Stage A pilot, A1 on `Reporting.Result`

- Worktree `feat/t5-a1` from `ficcus`. Rewrite `Reporting.Result` (133 lines) from the rank 2 CPS newtype to a first order step type with the same exported API; no consumer changes beyond compile fixes.
- Gates: full `gates.sh`; record compile time of the typed corpus and `elm-spa-example` against the parent binary (three alternating rounds, medians).
- If within the limit, the same for `Optimize.Names.Tracker` (43 signatures, 4 files). Report: diff size, timings, any consumer that relied on CPS.
- Stop and report if any gate output differs.

## Session 2 (Opus or Sonnet): translator skeleton

- Worktree `feat/t5-skel` from `ficcus`. Create `ficus-tools/t5/` (own cabal project, `ghc` package). Build the compiler once with `-fwrite-ide-info` into a scratch `hiedir` (`cabal.project.local`, not committed).
- Implement `t5 survey` (exact section 1 table per module, call graph and tail call SCCs, UNMAPPED preview) and check that HIE gives the type of every `do` node in `Parse.Number` and `Canonicalize.Pattern`.
- Implement R1 to R8, R17, R19 to R21 and the printer; translate `Data.Index`, `Data.NonEmptyList`, `Data.OneOrMore`, `Data.Bag`; compile them with the current `elmfic` binary.
- Implement the harness for those four modules (section 5, steps 1 to 4, 6) and report cases, differences, the UNMAPPED list and the time per module.

## 9. Addendum: the user's Elm in Elm port (27 Nov 2026)

Source: `reference/elm-in-elm/elm-compiler.zip` (commit `afba103`, 9 Sep 2024, Elm 0.19.1), unzipped outside the repo. Earlier ports under `reference/`: pithub's `elm-compiler-in-elm` (154 modules, 48,250 lines, whole compiler, type classes emulated) and `elm-compiler-in-elm-cli` (2 modules), both BSD 3 clause (attribution if code is taken; none is). Used only as a cross check.

### 9.1 Inventory

74 modules, 20,789 lines; module names are the Haskell paths under a `Compiler.` prefix. 73 compile with `bin/elm0191`; `Type.Solve` stops mid edit (line 158). **No tests:** `Main.elm` times parsing of six inline sources (Tailwind utilities, about 50,000 lines, in 4.35 s on Chrome).

| Group | Elm / Haskell lines (`ficcus`) | Notes |
|---|---|---|
| 42 close translations: `AST.*`, all 9 `Canonicalize.*`, 10 `Type.*`, `Reporting.Doc`, `Render.*`, `Result`, `Error.Type`, `Error.Canonicalize`, `Optimize.DecisionTree`, `Elm.Interface`, `Kernel`, `ModuleName`, `Version`, `Data.Index`, `Bag`, `OneOrMore`, `NonEmptyList` | 14,833 / 15,397 | 0.19.1 semantics |
| 13 `Parse.*` | 3,592 / 4,205 | redesigned on elm/parser's `Parser.Advanced` (copied, fixed): `String` plus offset, `Good Bool`/`Bad Bool` with a problem bag; language extensions (`_` in numbers, `NaN`, negative case patterns, `[a]` types) |
| 9 stubs: `Error.Syntax` (495 / 6,198), `Error.Docs`, `Warning`, `Elm.String`, `Elm.Package`, `AST.Optimized`, ... | 1,057 / 7,927 | partial |
| Libraries: `Data.Map` (39 functions, Haskell argument order, over `Dict`, `comparable` keys), `Data.Name` (`Name = String`), `Data.STRef` (`s -> (s, a)`, refs index a `Dict Int`), `Data.Graph` (SCC), `Data.Pretty` | 1,259 | reusable |

Not started: the rest of `Optimize`, `Nitpick`, `Generate`, `Json`, binary encoders, `builder/`, `terminal/`, `Ficus.*`: about 60,000 of the 79,490 lines.

**Drift:** 56 of the 64 Haskell counterparts changed by 20 lines or more since `0.19.1` (mostly upstream 0.19.2/0.19.3; Ficus adds e.g. 329 lines to `Type.Solve`). The port cannot be the self hosted source without redoing those diffs by hand at every merge: it is a second reference and a library source; the translator stays.

### 9.2 The six rank 2 monads

| Monad | In the port | Stage A becomes |
|---|---|---|
| `Reporting.Result` | **done**, as A1's step type: `Result (RState i w -> RType i w e a)`, `Good a st \| Bad i w errs`; adds `map2`, `andMap`, `discard`, `chain`, `traverse*`. **Differs:** `map2`/`andMap` stop at the first `Bad`, Haskell's `<*>` runs the second action and joins the errors (`OneOrMore.more`; pithub keeps this); `traverseList` runs actions in reverse and returns the list reversed | A1: adopt the type and API names, keep Haskell's accumulation; harness: CPS original against the A1 Haskell version and the Ficus library |
| `Parse.Primitives.Parser` | **partly**: works, but a different design | A1 as planned (`Cok/Eok/Cerr/Eerr`, rev 181; pithub has this exact type). The user's parser is not adopted: its dead ends cannot give `Error.Syntax`'s text, and its extensions change accepted programs. Its idioms are kept (`chain`, `loop`/`Step`, bounded chains) |
| `Reporting.Task`, Json and Bytes `Decoder`, `Optimize.Names.Tracker` | **open** | unchanged |
| (not rank 2) `IORef` union find, A4 | **done**: `Type.UnionFind` over `Data.STRef` (`STUF`), threaded through `Solve`: G21's design | A4: adopt the design (`IntMap` in Haskell), moved before the Parser |

### 9.3 Rules against the user's conventions

Read: `Reporting.Result`, `Parse.Primitives`, `Parse.Number`, `Canonicalize.Pattern`, `Data.STRef`, `Type.UnionFind`.
**Confirmed:** R2 (`type ZeroBased = ZeroBased Int`), R3 (record alias), R12 (the shim exists; about 47 of the 86 functions to add), R21, R22 (`STRef`, `State` as `s -> (s, a)`), R25 (members per monad, no emulation), decision 7 (`Name = String`).
**Changed to the user's form:**
- **R1:** modules get the `Compiler.` prefix (`builder/` → `Builder.`, `terminal/` → `Terminal.`), so `Json.Decode`, `Parser`, `Task` cannot clash with packages; an import alias that shadows a default import is renamed by table (`Reporting.Result as MResult`).
- **R3:** field `_name` → `name_`, not `name` (`_type` cannot become a keyword; no clash with locals).
- **R9:** each bind is `M.chain m <| \x ->` on its own line, the rest of the block below at the same indent; `m >> k` → `M.chain m <| \_ ->`. Same meaning, keeps the `do` layout, diffs line by line.
- **R10:** `f <$> a <*> b <*> c` → `M.ok f |> M.andMap a |> M.andMap b |> M.andMap c` for any length; `M.map` for one argument.
- **R12:** keys stay derived `compare` types (A4b); the user's tuple encodings (`ModuleName.Comparable`) are an Elm workaround, not repeated.
**Contradicted:** `Maybe.withDefault (Debug.todo "...") m` (`Canonicalize/Environment/Foreign.elm:116`, `Canonicalize/Expression.elm:578,580`) crashes whenever evaluated, because Elm is strict. R7 gains: `fromMaybe (error s) m` → `case m of Just v -> v; Nothing -> Crash.crash s`; a crash is never an argument.
**R27 (new):** stack saving loops (the user's `Canonicalize.Pattern.sequenceA` opens `Result`'s constructors) live once in the monad library, never in a consumer module.

### 9.4 Pilot order, sessions and rate

1. **Pure:** as section 6; the translator's output is diffed against the user's modules (names normalized). A difference is 0.19.1 to 0.19.3 drift or a rule defect: this replaces section 4's golden reference paragraph.
2. **Result:** library from the user's `Result`, accumulation restored; `Canonicalize.Pattern` and `Canonicalize.Type` diffed against the user's.
3. **Union find (new):** `Data.STRef` and `Type.UnionFind` as library, `Type.Occurs`, `Type.Instantiate`; gate the types matrix.
4. **Parser**, 5. **IO**: unchanged.

**Rate:** the port gives no session rate (hand work over 2024). It saves about 1,500 library lines (`Map`, `STRef`, `UnionFind`, `Result`, `Name`, `Graph`, `Pretty`) and gives a second reference for about 15,000 lines, shortening harness debugging there. Revised: **28 to 45 translation sessions plus 4 to 6 for kernels and shims** (was 30 to 50 plus 5 to 8); the pilot still decides.

### 9.5 For the user to decide

1. `Result` accumulates errors as in Haskell (needed for equal multi error reports): confirm, and whether to fix the port too.
2. R1 `Compiler.` prefix and R3 `name_` fields.
3. The user's parser: reference only (recommended), or base of a later Ficus parser (changes error text; a separate project).
4. Its extensions (number `_`, `[a]` types, negative patterns): record as Ficus decisions or drop; outside T5.
5. Port code copied into the repo as library sources (the zip has no licence file): yes or no, and the licence.
6. Finish the port's `Type.Solve`, or freeze it (T5 does not need it).
