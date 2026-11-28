# W7: tooling and the package model (design note)

28 Nov 2026, branch `design/w7` from `ficcus` `eabd2ce5`. Nothing built. Sources read: PHASE1 items W7, W7-note and CTE;
the 28 Nov PROPOSED entries on commands, `repl` and C bundling; FFI-D8 (`docs/FFI-DESIGN.md` §4 on `design/ffi`); the T5
addendum §9; the file list of `terminal/src`. Marks: **[S]** checked in source, **[A]** assumption not checked.
Costs are in sessions (Sonnet unless marked Opus). Names use the post R1 spelling (`ficus`, `ficus.json`, `FICUS_HOME`).

## 0. One executable

`ficus` is one binary with subcommands: `make`, `init`, `install`, `publish`, `diff`, `bump`, `repl`, `reactor` (later),
`test`, `format`, `lsp`, `playground`. The Elm 0.19.3 terminal already has `Make`, `Init`, `Install`, `Publish`, `Diff`,
`Bump`, `Repl` and `Develop` (the reactor) [S], so seven of the twelve exist as starting points. An `elm.json` project keeps
Elm's behaviour under every inherited command, and Elm's flags keep their meaning. New commands add flags and never change old ones.

The bootstrap scope is `make` only (T5). Everything else here is Haskell code that the self-hosted compiler must port later, so
each tool stays a thin layer over shared compiler modules (parser, `Details`, reporting). The one exception is `format` (§5).

## 1. The package model and `install`

**Scope.** `elm.json` projects keep using the Elm registry through the existing `Http` and `Deps.Solver` path [S], plus the Ficus
overlay substitution for `elm/json`, `elm/bytes`, `elm/parser`, `elm/random`, `elm/regex` and `elm/time` [S `Details.hs:282`].
Ficus native packages (the ones allowed to carry C, by FFI-D8) come from **git clones** and need no registry.

- **Identity and source.** A package is `author/name`. Its source defaults to `https://github.com/author/name`. A `"sources"`
  table in `ficus.json` may map it to any git URL (Codeberg, a private host, a local path for development).
- **Versions are tags.** Only tags of the form `X.Y.Z` (and `vX.Y.Z`, read as the same version) count, and other tags are
  ignored. The solver gets its candidate list from `git ls-remote --tags` instead of the registry's all-packages list. An
  application pins exact versions, as Elm does, and a package gives ranges, as Elm does.
- **Cache.** `FICUS_HOME/<compiler-version>/` holds `git/author/name.git` (a bare mirror, fetched and never checked out) and
  `packages/author/name/X.Y.Z/` (the tree at the tag, taken with `git archive` with no `.git` and no submodules, then
  read only). A second project reuses both. `--offline` uses only the cache. `ELM_HOME` stays for `elm.json` projects, and R1-home
  renames only the Ficus one.
- **Hash check.** A git tag can be moved, and a registry release cannot. The application's lock data (a `"lock"` section in
  `ficus.json`, or `ficus.lock`, see Q2) records for each package the commit id of the tag and a SHA-256 of the archived tree.
  A later install that finds a different commit or tree is an error naming the package and both commits. It is never silently
  accepted. `install --update author/name` is the one way to accept a moved tag. The hash check also covers mirrors and
  proxies.
- **C carrying packages.** As in FFI-D8: an application lists them in `"c-packages"`, and a dependency that brings C without
  being listed is a build error. When it adds a package that carries C, `install` prints the C files, `pkg-config` names and
  flags it brings and asks for confirmation (`--yes` skips the prompt). The C sources sit inside the hashed tree. Include
  directories and sources must be relative paths inside the package: absolute paths and `..` are refused.
- **Code execution at build time.** This is the real risk of any package system, so it is listed in full:
  (a) **No build scripts, no install hooks**, ever. Nothing in a package runs at `install`.
  (b) **Compile time evaluation (CTE/H22)** runs package code inside the compiler. Ficus code is pure, so the risks are
  resources (non-termination, memory) and determinism, not effects. A step and memory budget applies, and exceeding it leaves the
  expression for run time (with a note) and does not fail the build. CTE never calls an `extern`: an expression that reaches
  one is left for run time. Package C therefore never runs at build time.
  (c) **The C compiler** reads package C. It does not run it, but compiler flags can: `-fplugin=`, `-wrapper`, `-B`, `-specs`
  and response files `@file` load or run code. FFI-D8's `cflags`/`ldflags` from packages pass through an allowlist (`-D`, `-I`
  inside the package, `-O*`, `-W*`, `-std=`), and only the application's own `ficus.json` may give other flags.
  (d) **`pkg-config`** runs on the user's system with names from the package. Names are checked against `[A-Za-z0-9_.+-]+`.
  (e) **The program itself** runs package C at run time. That is the trust the allowlist expresses and cannot be removed.

**First slice I1.** Exact versions only (no solver): `install author/name X.Y.Z` mirrors, archives, hashes and writes the
lock; `make` builds an application that depends on a git package; tests with local bare repositories (a moved tag, an offline
run, a non-tag ref refused).
**Then:** I2 solver over tag lists (reusing `Deps.Solver` with a second source of versions); I3 the C allowlist (with FFI-a).
**Cost:** I1 2, I2 1 to 2, I3 0.5 (inside FFI-a). One short Opus review of the hash and moved-tag rules after I1.
**Depends on:** R1 and R1-home (names), the `ficus.json` schema (FFI-D8 adds `c-ffi`; both should land in one schema decision).

## 2. `publish`, `diff`, `bump`, `init`

**`publish` (stripped).** With no registry it uploads nothing and only checks: version in `ficus.json` is a semver tag on HEAD,
the tag is pushed (`git ls-remote` on the source URL), the tree is clean, exposed modules build, `docs.json` builds, every
exposed value has a doc comment (as Elm), README and LICENSE exist, `c-ffi` is declared if C is present, and the version
step matches what `bump` would compute against the previous tag. It ends by printing the dependency line a user adds.
A later index (a git repository listing known packages, for search and a docs site) is optional (Q4).

**`diff`.** Elm's `diff` compares the docs of two registry versions [S `Diff.hs`]. The new forms are `diff <ref> <ref>` (any
git refs, materialised with `git archive` into a temporary directory) and `diff <dir> <dir>`. Both build the interface of each side
and reuse the existing API comparison and magnitude logic. Ficus additions that count as API: attached functions, sized number
types, `extern` declarations (changing a signature is MAJOR). A change of `c-ffi` link settings is at least MINOR and is
reported in its own section, because it changes what a user must have installed.

**`bump`.** The previous version is the highest semver tag that is an ancestor of HEAD. `bump` runs `diff` between that tag and the
working tree and rewrites `version` in `ficus.json`. With no tag it proposes `1.0.0`, as Elm does.

**`init`.** It writes `ficus.json` (application by default, `--package`), `src/Main.fic`, `.gitignore` (the build directory),
and an empty `tests/` with one EXPECT example (§4). `init --elm` keeps today's `elm.json` behaviour.

**First slice:** `init` plus `diff` on dirs and refs. **Cost:** `init` 0.5, `diff` 1, `bump` 0.5, `publish` checks 1:
**3 sessions**. **Depends on:** I1 (schema, tag reading). Outside the bootstrap scope: the code stays in Haskell until a port is needed.

## 3. `repl`

**Scope.** Elm's `repl` compiles each input to JS and evaluates it in `node` [S `Repl.hs`, 538 lines]. Ficus has two
backends:

- **JS (first).** Keep the Elm design: the Ficus JS output and a `node` that is either found on `PATH` or bundled (a
  `node` binary is about 40 to 50 MB, Q9). This is almost unchanged code. Values print through the `Debug.toString` kernel, which
  A4c already shares with `toString`.
- **Native through libtcc, in process.** Each input becomes C for the new definitions plus one entry function. It is compiled with
  `tcc_compile_string` and relocated, and earlier entries' symbols are given to the new state with `tcc_add_symbol`. The runtime
  (`ficrt`) is compiled once into the first state so there is one heap and one set of counts. The installed `libtcc.a` is
  0.9.28rc for x86_64 [S]. Three points to watch:
  (1) **Crashes:** a segfault or `Debug.todo` in user code must not kill the session, so the libtcc host runs in a
  child process (a small C server speaking over pipes). On a crash the parent restarts it and replays the definitions.
  (2) **Monomorphisation:** a new input can need new instances of earlier polymorphic definitions. The entry is compiled
  against the whole session's definitions, and instances are cached by name.
  (3) **Licence:** libtcc is LGPL. Linking it statically into `ficus` brings relinking duties. Linking it into the separate
  child server, or using `libtcc.so`, avoids that (Q8).
- **`reactor`** (the `Develop` code) stays JS only and comes after the playground, which supersedes most of it.

**First slice:** `repl` on the JS backend, with tests from Elm's `repl` transcripts compared against `bin/elm0193`.
**Cost:** JS 1; native 3 to 4 plus an Opus review of the child server protocol and the instance cache.
**Depends on:** the JS backend covering Ficus extensions [A]; native needs the C driver interface (§9).

## 4. `test` with EXPECT pragmas

**Proposed syntax** (must stay valid Elm, so `elm make` and `elm-format` accept the file): a block comment pragma at the
top level of any module, after the declarations it tests:

- `{-# EXPECT square 3 == 9 #-}`: passes when the expression is `True`. If the top-level form is `a == b`, `a /= b`, `a < b`
  and so on, a failure prints both sides through `Debug.toString`.
- `{-# EXPECT_CRASH parse "" #-}`: passes when evaluation reaches `Debug.todo` or a runtime abort (vector index etc.).
- `{-# EXPECT_OUTPUT "golden/name.txt" #-}`, in a `Main` module only: runs the program and compares standard output byte for
  byte, as `targets/run_all.py` does today.

The expression sees everything in the module, private names included, so tests sit next to the code (as Roc's `expect`). A
pragma is ignored by `make`, so it costs nothing in release builds. `{-#` is an ordinary comment to Elm [A: check that Elm's
lexer and elm-format keep it as written]. The fallback syntax is a line comment `-- EXPECT ...`, which is uglier for
multi-line expressions.

**Runner.** `ficus test [files]` collects pragmas from `src/` and `tests/`, type checks each expression in its module's scope
(errors point at the pragma line), and generates one synthetic entry module per tested module that evaluates each expectation
in order and writes one result line each. Output: a short human summary, `--report=json` for tools, non-zero exit on failure.
Pure tests are deterministic (no `Time`, no seeds from the clock).

**Backends:** `--backend js` (node; the default until native testing is quick), `native` (tcc for speed, `--release` uses
gcc or clang with `-ffp-contract=off`), `wasm` (node with the WASM build) [A: WASM backend maturity]. **`--backends js,native`**
runs both and compares the result lines. That is a cheap cross-backend differential check and fits the project rule "test
by differential comparison". For modules that compile under Elm, `--against-elm` also runs the JS through `bin/elm0193` and compares.
`elm-explorations/test` suites are a separate question (Q11).

**First slice T-1:** pragma parsing (comment kept by the parser with its region), type checking in scope, JS runner, summary.
**Cost:** T-1 2; native 1 (with the C driver); WASM 1; differential modes 0.5. **Depends on:** nothing new for JS; §9 for fast native.

## 5. `format` and `--report=json`

**`format`.** elm-format is a separate Haskell project (BSD 3 clause) with its own comment-preserving parser, distinct from
the compiler's (which drops comments). Options:
(a) **vendor elm-format** into the executable and extend its parser for the Ficus syntax (`extern`, sized literals, `1_000`,
`-1` patterns, `[a]` types if kept (SYN-3), EXPECT pragmas, attached functions);
(b) a new formatter on the compiler's parser, which first needs comments and exact layout kept, so a CST. That is the
error-tolerant parser work of §6, done twice.
**Recommend (a)** for the Haskell phase, and in the self-hosted compiler a formatter over the self-hosted parser's CST.

Rules: `--elm` reproduces elm-format 0.8.7 byte for byte on Elm files (gate: the 1,175 elmdiff files and the corpus, formatted by
both, must be identical). The default Ficus style applies the user's tweaks. **The user's list of rule changes is not in the
documents read** (Q6). Each tweak is one switch in the printer with its own golden cases, so `--elm` stays exact.
`format --validate`, `--stdin` and `--yes` keep elm-format's meanings, so editor plugins work unchanged.

**`--report=json`.** Editors (the VS Code Elm extension, elm-language-server) parse `elm make --report=json`. The fork keeps
Elm's `Reporting` code [S `Make.hs` `ReportType`]. Requirement: for any input Elm also rejects, the JSON is byte identical to
`bin/elm0193`'s. Ficus-only errors use the same shape (`type`, `path`, `name`, `problems` with `title`, `region`, `message`
chunks) with new titles. Gate: run both compilers over the type-issues cases and the KNOWN-REJECTS corpus and compare.
This is the cheapest editor support available: elm-language-server pointed at `ficus` gives diagnostics on day one (it
parses with tree-sitter-elm, so Ficus-only syntax shows parse noise there).

**First slice:** the `--report=json` gate (0.5 to 1). Format: vendor and build in 1, Ficus syntax 2, tweaks 1, compatibility
gate 1: **5**. **Depends on:** SYN-3 (which extensions exist), the EXPECT syntax (§4), the user's tweak list.

## 6. `lsp` v1 and the error-tolerant parser

**v1 scope** (stdio JSON-RPC, inside `ficus`): diagnostics on save (one incremental `make` through the cached `Details`,
reported with the `--report=json` data); go to definition (canonical AST regions); hover with the type of top-level names
(interfaces have them) and, if cheap, of local names (needs the solver's results per node kept: the typed IR may already give
this [A: `TYPED-IR-DESIGN.md` not read]); document symbols; formatting through `format`. **Not v1:** completion, rename,
find references across packages, diagnostics while typing.

**The parser dependency.** Elm's parser stops at the first error [S, T5 note], so a module with one syntax error has no AST, and
hover and definition die while the user types. v1 keeps the **last good AST per module** and marks results as stale. That is
acceptable for v1. The next step is **declaration level recovery**: split the module at column-0 declaration starts, parse
each piece, keep the good ones, and report errors per piece. That is a wrapper around the existing parser (1 to 2
sessions) and gives most of the value. Full tolerance (a CST with error nodes, also needed by `format` (b)) belongs in the
self-hosted parser: the stepper (state machine) form the user approved on 28 Nov has explicit states where error nodes can
be inserted, and the planning chat already put error collecting under W7.

**Library:** the Hackage `lsp` package (a new dependency that changes the freeze file, Q7) or a hand-written JSON-RPC loop
(about 400 lines, `aeson` already present [A]).
**First slice:** diagnostics plus definition over stdio, tested by a scripted client.
**Cost:** v1 3 to 4 plus an Opus review of the hover data source; declaration recovery 1 to 2. **Depends on:** `--report=json`
gate, format (for formatting), a cabal library split (§8).

## 7. `playground`

**v1 (localhost, JS):** `ficus playground` starts an HTTP server on 127.0.0.1 (the reactor's server code [S `Develop/`]),
with one page: an editor (CodeMirror shipped inside the binary as static files, no CDN, works offline), compile on demand
with the JS backend, output in a sandboxed iframe, errors rendered from the JSON report, and a view of the generated C.
**Native run** (compile with tcc, run, show stdout) is a second step. Because that executes code, the server needs a random
token in the URL and must check `Origin`, or any web page the user visits could post code to it. It also gets a time and
memory limit per run.

**GUI later:** a native window (the "Tauri like interface" of the 27 Nov note) wrapping the same page, so the page is the
product and the window is packaging. It is a separate decision after v1 is in use.

**First slice:** server, editor, JS compile and run. **Cost:** v1 2; native run and C view 1; GUI 3 or more (later).
**Depends on:** the JS backend; lsp only for in-editor hints (later).

## 8. The compiler as a library

There are three readings, with different answers:

1. **A Haskell library for the subcommands.** A cabal split (`library` with the compiler and builder modules, the executable
   thin). It is internal, with no stability promise, and needed by `lsp`, `test` and `playground` to avoid process overhead.
   Recommend: do it when `lsp` starts. It touches `cabal.project.freeze` only if dependencies change (ask first in any case).
2. **A stable external API for other tools.** Better as **protocols** than as linking: `--report=json`, LSP, the test JSON,
   the playground's compile endpoint. These survive self-hosting unchanged, where a Haskell API would not.
3. **A Ficus library** (`ficus/compiler` as a package) after self-hosting. It enables tools written in Ficus and
   reuses the compiler's parser for `format` and `lsp`. It needs T5 to finish.

**Recommend:** 1 now, 2 as the public contract, 3 after T5. The checklist's "compiler as library note (Opus)" reduces to
this section unless the user wants a public Haskell API (Q10). **Cost:** split 1. **Depends on:** nothing.

## 9. Bundling a C compiler (options only) and compile time evaluation

**C driver interface** (planning proposal, 28 Nov): one interface "compile this C, give an object, executable or callable
symbol" with two implementations, in process libtcc and an external `cc` (gcc or clang). Users of it: `make` with a `--cc`
convenience (FFI-D8 says the compiler does not run cc today), `repl`, `test`, playground native run, and possibly CTE.

**Bundling options:**

| Option | Contents | For | Against |
|---|---|---|---|
| A. None | system `cc`/`$CC`, system tcc if present | zero size; best code; current behaviour | Windows and macOS users install a toolchain; `repl`/`test` speed depends on what is installed |
| B. libtcc only | libtcc (about 300 KB) plus `libtcc1.a` and tcc's headers | fast `repl`/`test`/playground everywhere; release builds still use system cc | LGPL handling (child server or `.so`); tcc needs libc headers (on Linux the system ones; on Windows tcc ships its own) [A]; weak code |
| C. zig cc | clang plus libc headers for all targets (tens of MB) | one compiler for every target, cross compiling | large; a separate project's release cadence; slower start than tcc |
| D. Downloadable toolchain | `ficus toolchain install` puts tcc or clang into `FICUS_HOME` | small main binary; opt in | network at first use; one more moving part |
| E. B plus D | libtcc bundled, clang downloadable | fast loop out of the box, best code on request | two toolchains to test |

The decision criteria are platforms supported in Phase 1, binary size budget, and whether the Float printing and
`-ffp-contract=off` guarantees hold under every C compiler offered (the byte-equality rule applies to all of them).

**Compile time evaluation (CTE, H22) and the driver.** Constants found at compile time are baked into the output, so the
JS and C backends must bake **identical** values. Two ways:
(i) a budgeted **interpreter over Mono IR** in the compiler: one semantics for all backends, deterministic, no C
compiler needed, sandboxed by construction, slow for heavy work;
(ii) **compile to C and run through the driver** (tcc): fast, but the results come from native arithmetic, so Float and
`Int` edge cases must be shown equal to the JS semantics. It needs a child process with resource limits, and no externs (§1).
The requirement on both: a step and memory budget with fallback to run time (never a failed build), no effects, results
independent of host and backend. The H22 note should choose. Here the note only records that (ii) depends on option B, D or E
above, and (i) on none.

**Cost:** driver interface with both implementations 2 (one Opus review). **Depends on:** the bundling decision for B to E.

## 10. Time-travel debugger, per backend

The debugger depends on `update` being pure. It records messages and rebuilds any past model by replaying from `init`, or keeps
snapshots.

- **JS:** Elm's `--debug` (elm/browser's debugger kernel). First slice: parity with Elm on a Browser program, checked
  against `bin/elm0193`. Limits: the value viewer must learn Ficus values (vectors, sized numbers, `Int` beyond 2^53), and
  export and import of the history needs the message types to be encodable (Elm already restricts this).
- **WASM:** the model lives in linear memory under reference counting. Keeping old models alive means holding a reference to
  each. That also turns off Perceus in-place reuse for anything shared with history, which is correct but slower and
  larger, acceptable in a debug build. Inspection needs an exported `toString`. Viewer: the JS debugger UI over exports.
  Later than JS.
- **Native:** no browser, so the debugger is **record and replay**: log the flags, every message, every subscription event and every
  Task result (time, random seeds, ports, HTTP, `extern task` results) to a file, and replay offline through the E1
  typed stepper. E2's deterministic mode makes the replay exact. **Limits:** T1 threads are deterministic only under E2's
  mode; `extern type` handles in the model cannot be logged, so replay re-runs from `init`, which recreates them, and C
  libraries with hidden state (a C random generator, say) break exactness. Pure externs are fine. The viewer is the
  playground page reading the log.

**Cost:** JS parity 1 to 2; native record and replay 3 to 4 plus an Opus review; WASM after the WASM backend settles.
**Depends on:** E1 (done), E2 deterministic mode, the playground for a native viewer.

## 11. Recommended order

| # | Item | Sessions | Why here |
|---|---|---|---|
| 1 | `--report=json` gate (§5) | 0.5 to 1 | cheapest; editors work at once through elm-language-server |
| 2 | `init`, I1 git install, hash lock (§1, §2) | 2.5 | after R1 and R1-home; unblocks package work in parallel sessions |
| 3 | `test` T-1 on JS (§4) | 2 | every later session (packages, FFI) writes EXPECT tests |
| 4 | C driver interface (§9), then native `test` | 2 + 1 | needs the bundling choice; also serves FFI-a and CTE |
| 5 | `format` (§5) | 5 | needs SYN-3 and the tweak list |
| 6 | `repl` JS, playground v1 (§3, §7) | 1 + 2 | visible progress, low risk |
| 7 | I2 solver, `diff`, `bump`, `publish` (§1, §2) | 4 | when the first packages are published |
| 8 | cabal split, `lsp` v1, declaration recovery (§6, §8) | 1 + 4 + 2 | after format and the JSON gate |
| 9 | native `repl`, playground native run (§3, §7) | 4 + 1 | after the driver |
| 10 | debugger JS, then native replay (§10) | 2 + 4 | after E2 deterministic mode |

Total about **33 to 40 sessions** (plus 5 short Opus reviews), excluding the GUI playground, WASM work and full tolerant parsing.

## 12. Questions for the planning chat

1. **Elm compatibility of commands:** on an `elm.json` project, must every inherited command behave exactly as Elm 0.19.3
   (output text included), or only `make`?
2. **Lock data:** a `"lock"` section in `ficus.json` or a separate `ficus.lock`? Non-GitHub hosts and local paths allowed?
3. **Moved tags:** hard error (recommended) or a warning?
4. **Package index:** a git repository listing packages for search and docs, now or later?
5. **EXPECT syntax:** `{-# EXPECT ... #-}` (recommended) or `-- EXPECT`; may tests see private names (recommended yes)?
6. **Format:** the user's list of rule tweaks; is the default output Ficus style with `--elm` for exact compatibility?
7. **Dependencies:** may W7 add Hackage packages (`lsp`), changing `cabal.project.freeze`?
8. **libtcc licence:** child server process (recommended) or `libtcc.so` beside the binary?
9. **Bundling:** which option of §9, which platforms in Phase 1, and is a bundled `node` acceptable for the JS `repl`/`test`?
10. **Compiler as library:** is a public Haskell API wanted, or are the protocols of §8 enough (recommended)?
11. **elm-test:** should `ficus test` also run `elm-explorations/test` suites, or are EXPECT pragmas the only test form?
12. **CTE:** should the H22 note choose interpreter or tcc, given that backends must bake identical values?
