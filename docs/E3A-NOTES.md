# E3a + E3b: the ports value API, Array payloads, error texts, flags (session notes)

27 Nov 2026, branch `feat/e3a` from `ficcus` 75e3ed9a, worktree `ficcus-haskell-compiler-e3a`. Implements slices E3a and E3b of
`docs/E3-PORTS-DESIGN.md` (branch `design/e3`), decisions D1 to D16 as approved, with D11: both `FIC_FLAGS` and `FIC_FLAGS_FILE` set
refuses the run. Binary `bin/elmficE3a`. Not in this session: E3c (Ficcus only payloads, range checks, `JUINT`), E3d (raw vectors,
D9, D10's staging buffers), E3e (embedding loop, threads, `fic_app_stop`, `FIC_E_THREAD`), E3f (benchmark).

## 1. First step: what Elm 0.19.3 does (bin/elm0193, node 21, debug build)

Program with ports `inn` (record), `mb` (Maybe Int), `tup` (tuple), `out`, and two ports that `main` never uses; driven from JavaScript.

- **Crash 4 prints `[object Object]`** (the note said "probably"; confirmed): `send("x")` on a record port throws
  ``Trying to send an unexpected type of value through port `inn`:`` + newline + `[object Object]`. The Ficcus runner prints
  `errorToString` of the same error as the second line instead, as D7 decided (a recorded deviation, stderr only). The E3 tests
  compare that text with Elm's by patching the compiled JavaScript to print `Json.Decode.errorToString problem` (ref/run3.js).
- **Unused ports are absent** from `app.ports` (`unused`, `unusedIn` declared, never used): the reachable set, as the C side's
  manager table already has.
- **Absent flags** (`init({})` with `Program Int`) give crash 2 with `undefined` as the value: `Problem with the flags given to your
  Elm program on initialization.` / blank / `Problem with the given value:` / blank / `undefined` / blank / `Expecting an INT`.
- **Record fields are tried in the reverse of Elm's (length, bytes) order**: `{name, age, xs}` sent `{"zzz":1}` reports `name` first
  (Optimize.Port.decodeRecord folds `fieldAndThen` over `Map.toList`, so the last field is the outermost decoder).

## 2. What was built

| Decision | Where | What |
|---|---|---|
| D1, D2, D3 | `runtime/fic_ports_api.h` (declarations, also the top of the generated header), `runtime/fic_ports.h` | `fic_hv` = a Json.Value node; builders (`array`/`object` + `_set` + `finish`, L35 order, last duplicate wins in the first place), readers, `retain`/`release`; `send` consumes (also on failure), callbacks borrow; the decoded value is delivered after the host's tree is released, so a received leaf keeps only its own count (D3's move) |
| D2 header | `Ficcus.Mono.PortsHeader`, `Make` | `<Module>_ports.h` beside the C for a program with ports or flags other than (): the API text, per port its direction, Elm type, JSON shape and `#define FIC_PORT_<name> "<name>"`, the flags type |
| D4 | `fic_hv_string`, `fic_hv_string_alloc`/`seal` | UTF-8 validated (no overlong forms, no surrogates, at most U+10FFFF), one copy in; zero copy out |
| D5 (Elm's rules) | the generated decoders | Int: an Int node or a whole Float below 2^63 in size (now the same rule as `Json.Decode.int`, L21; E2's port decoder used ±9.2e18); Float: any number; NaN and the infinities pass the value API and print as `null` (L20) |
| D6 Array | `CGen` portEncBody/portDecBody, `fic_port_array_build`/`_words` | `Array` in and out as a JSON array; the decoded Array is built as Elm's `Array.fromList` (Elm's `Json.Decode.array` uses `Array.initialize`, the same tree), tested up to 32803 elements (shift 15) and compared with `==` on Elm's own arrays |
| D7 | `fic_pd_explain`, `fic_ets_*`, `fic_port_error` | codes, no exit; on a refused value only, the Error of Elm's decoder (Maybe as oneOf, tuples by index, records field by field in Elm's order, Array, List) and elm/json's `errorToString` line for line; only the runner exits (crash 4 line + errorToString) |
| D8 | `fic_port_send_json`, `fic_hv_to_json`, `fic_hv_from_json` | JSON.parse / JSON.stringify; not JSON: `FIC_E_DECODE` with `errorToString (Failure "This is not valid JSON! Syntax error" text)` (L27); the runner is a subscriber like any other (`fic_runner_start`) |
| D11 | `fic_app_start`, `fic_flags_env`, `fic_flags_take`, `Spec.specWorker`, `CGen.appStart`/`hostMain` | flags of any port type: `FIC_FLAGS` or `FIC_FLAGS_FILE` (both: refused, exit 1); absent = `JUNDEF` (prints `undefined`); crash 2 text, exit 1, before `init`; `fic_app_start` returns `FIC_E_DECODE` with that text; () flags are never read |
| D12 | `fic_port_out_effects`, `fic_port_subscribe`/`unsubscribe` | Elm's `subs` array: subscribe pushes onto the array being read (called for the same value), unsubscribe replaces it by a copy (the delivery goes on with the old one); a callback may send (nested update) |
| D15 (part) | `fic_ports_stop` | after the end every port call is `FIC_E_STOPPED` |

## 3. Deviations from the note

1. **Error texts without compiled Elm code.** The note builds `fic_jd_*` decoder trees from a type description and calls the
   compiled `errorToString`. Instead `fic_pd_explain` walks the value along a static type description (a short string the compiler
   emits, `PortDesc.portDesc`) and builds the same Error with the existing `fic_jd_*` error constructors, and `errorToString` is ported
   to C line for line (it is 60 lines of Elm). Same texts (48 refused values compared with Elm: 36 port sends, 2 runner crashes, 10 flags; nested oneOf included), no closures, no
   extra clones in the program, and nothing runs on success.
2. **`fic_sched.h` is unchanged.** Its E2 port section (under `#ifdef FIC_TAG_JNULL`) is replaced by `fic_ports.h`; to keep the C
   text of every program without ports byte identical (also those with the scheduler), the generator wraps `fic_sched.h` in
   `#undef FIC_TAG_JNULL` / `#define FIC_TAG_JNULL 0xFFE0u` in programs that have ports or flags. The old section is dead text there.
   Remove it when a slice may change the C of scheduler programs.
3. **API additions:** `fic_hv_from_json` (the parse alone: the flags and the runner need it), the kind `FIC_HV_INVALID` (NULL, an
   unsealed builder), and in a program with flags but no ports the port functions exist and answer `FIC_E_NO_PORT` (a host links
   against any program). Not added (later slices): `fic_hv_uint`/`get_uint` and `JUINT` (E3c), `FIC_HV_VECTOR` values (E3d),
   `FIC_E_THREAD` checks (E3e).
4. **Test host hook.** A host program is linked by compiling the generated C with `-DFIC_HOST_MAIN=<function>`: `fic_main` calls it
   instead of reading the flags and starting the runner (the host calls `fic_app_start`). The embedding loop proper is E3e.
5. **C unit tests** are a host program against a generated program (`effects3/host/host_api.c` with `E3Api.fic`), not
   `runtime/test_ports.c`: the value API needs the JSON, string and closure runtimes of a program.
6. **() flags are never read**, so `FIC_FLAGS` text that is not JSON, or both variables, do not stop such a program (Elm's decoder is
   `succeed ()`; and those programs keep their C).
7. **Json.Value and undefined:** absent flags of type `Json.Value` refuse to start (as D11 says) with the text
   `Expecting a value: no flags were given, and Ficcus does not pass JavaScript's undefined into a Json.Value` inside crash 2's text;
   the same holds inside `Maybe Json.Value`: absent flags of type `Maybe Json.Value` refuse to start too, where Elm gives
   `Just undefined` (oneOf's `Json.Decode.value` takes undefined first; checked against Elm in the E3a review, N5).
8. **`fic_port_error()` stays valid until the next failure** (D2 said "until the next call"); successful calls do not clear it.
9. **A record field is an own key of a JSON object** (E3a review F4, with the `length` corner of section 6 point 2). Elm's
   `Json.Decode.field` tests with JavaScript's `in`, which also finds keys that every object or array inherits: `length` on arrays,
   and `constructor`, `toString`, `valueOf`, `hasOwnProperty`, `__proto__` and the like on `{}` and `[]`. Elm: `{ constructor : Int }`
   given `{}` fails at `json.constructor` with "Expecting an INT" (value `undefined`), and `{ constructor : Json.Value }` given `{}`
   is **accepted** (a JavaScript function enters the program and encodes as `undefined`). Ficcus refuses both with "Expecting an
   OBJECT with a field named `constructor`" (fast decoder and error walker agree; no `internal:` text). Reproducer: the `pCtor` and
   `pCtorV` lines of `ficcus-tests/e3ar/mklines.py`.

## 4. Tests

`ficcus-tests/effects_e3.py` (goldens: `--goldens --ref ../bin/elm0193`; expected files `expected/e3_<case>.{out,err,code}`), 31
cases, each run `--rc` (gcc -O2, ASan + UBSan without the pool, `-DFIC_DROP_ALL`) and `--no-rc` -O2: 124 checks of stdout, stderr
(without the FIC_STATS lines) and exit status; `live 0` and `0 bad, 0 live after the free` for every run that ends normally.

| Case | Expected from | What |
|---|---|---|
| array | Elm | Array in/out: 0, 1, 32, 33, 1056, 1057, 32803 elements; records, nested Arrays, Floats; `==` with Elm's arrays, push/set/slice/append on received arrays |
| errors | Elm | 61 sends (36 refused) through a host that catches failures: every decoder, nested oneOf, `['my_field']`, unknown port |
| errors_runner | Elm | the runner's crash 4: stdout up to the failure, exit 1, errorToString on stderr |
| reentry, reentry_unitflags | Elm | D12: a callback that sends at once, one that unsubscribes itself, subscribe during a delivery before and after an unsubscribe; () flags not read |
| flagsint_* (9) | Elm, 2 by hand | Int flags: 42, 1e3, null, a string, absent, a file, both variables (hand: D11), text that is not JSON (hand), through `fic_app_start` (value, NULL) |
| flagsrec_* (5) | Elm | record flags of every kind (List, Maybe, tuple, Array, Json.Value, nested record), a missing field, a nested wrong type, an Array element, absent |
| flagsvalue_* (2) | Elm, 1 by hand | Json.Value flags; absent (hand: the deviation of D11) |
| flagsmaybe_* (3) | Elm | null, 5, absent (oneOf's two failures with `undefined`) |
| api | by hand | the value API: builders, L35 order, unset slots, setters' codes, shared builder, UTF-8 refusals, `string_alloc`/`seal`, JSON text, codes and texts of every port call, a retained value read later, `FIC_E_STOPPED` after the end |
| x1flags, x1flags_missing, x1flagsstring, x2arrayportout, x3arrayportin | Elm | the E2 review's rejects X1 to X3 (compile errors until E3), now run; moved from `e2review/rejects` (e2_review.py keeps X4 to X6) |

`effects_e2.py` all ok and `e2_review.py --targets` all ok except the four retired rejects (before they were moved): the runner
rebuilt on the API prints the same lines.

## 5. Gates (bin/elmficE3a, once, at the end)

27 Nov 2026, 06:41 to 08:16 (queued behind another session's gate run), `BIN=elmficE3a A3B_REF=bin/elmficA5c KEEP=1`, log
`/home/gordon/claude-tmp/gates-e3a.log`, files `/home/gordon/claude-tmp/gates-e3a/gates/`.

| Step | Result |
|---|---|
| runtime | 0 non-ok |
| attach | 340 cases, 0 differ |
| sized-fuzz | 40 seeds, 0 differ |
| stringdiff | all agree |
| types | 267 PASS, 1 XFAIL |
| jsid | 28 identical, 0 different |
| examples, ex-dropall, ex-rcsan | 298, 298, 298 ok |
| fbip | 0 failures |
| effects-e2, effects-e3 (new step) | all ok, all ok (124 checks) |
| e1review, effects-e1, e1p, e1pr | all ok; e1pr 2 target rows as before |
| e1p-identity vs elmficG70a | the gate run crashed in the tool on E2Ports (a sort of `None` with ints when the runtime prelude differs, which no slice before had); fixed (`ficcus-tests/e1p_identity.py`) and the step rerun alone: 51 ok, the 2 port programs FAIL as expected (E2Ports, E2PortsIn: the prelude and the last section, which holds the port decoders and the main; the generated code before the main differs only by the intended decoder changes: Json.Value refuses undefined, Int as `Json.Decode.int`) |
| a3b-identity vs elmficA5c | 100 compiles, 4 differ: E2Ports and E2PortsIn, --rc and --no-rc (the only port programs); every program without ports identical, also the scheduler programs |
| e2review | gates all ok (X1 to X3 moved to effects_e3), info 3 differ as before |
| rcfaults, rcfaults-big | 2403 mutations 0 missed; 239 mutations 0 missed |
| rcgate-san | ok |
| suite | 16 PASS of 16 |
| typed | 568 SAME, 12 BOTH_REJECT_SAME, 1 VERDICT_DIFF (as before) |
| lib-rcsan | 108 PASS, 59 FIXED, no regression |
| elmdiff | 1175 SAME, 0 DIFF |

## 6. Open points for the Opus review

1. **Ownership at the boundary:** `send` and the setters consume their value also when they fail; `finish` refuses a shared builder
   only in a counted program (without counts nothing can tell); the decoded value is delivered after the host's tree is released (a
   string the host did not retain arrives with count 1). A retained value seen by a callback stays valid (test `api`).
2. **Fast and slow decoders must agree.** The generated decoder decides; `fic_pd_explain` only explains. Where they would disagree the
   text is `internal: the generated decoder refused a value that Elm's decoder takes`. Known corner: a record with a field named
   `length` given a JSON array is accepted by Elm (`'length' in array`) and refused by both Ficcus decoders (as E2 did).
3. **The `#undef FIC_TAG_JNULL` wrapper** (deviation 2): correct only while nothing between the JSON runtime and the ports runtime but
   `fic_sched.h`'s port section reads that macro.
4. **The Array tree** is built with `floor(log(n - 1) / log 32)` like Elm's `logBase`; the arguments (a multiple of 32, minus 1) are
   never within rounding distance of a power of 32.
5. **D12** follows Elm exactly, including that a callback subscribed during a delivery is called for the same value only when no
   unsubscribe replaced the array first (test `reentry`, both orders); a test of nested deliveries across two ports is in the same case.
6. **Flags typed by a free variable** (`unitFlags`) are treated as `()` (never decoded), as before.
7. **`fic_app_start` runs once** (a second call is `FIC_E_INVALID`); there is no stop or restart before E3e.

## 6a. After the E3a review (`docs/E3A-REVIEW.md`; branch `feat/e3af`, binary `bin/elmficE3b`)

- **F1 fixed:** `portDecBody` declared neither the cons cell of its List branch nor the Just cell of its Maybe branch (`needObj`), so
  an incoming port or flags of `List String`, `List (Maybe Int)`, `List (Maybe String)` or `List (List Int)` did not compile
  (`fic_o_pp`, `fic_o_i`, `fic_o_p`, `fic_o_ip` undeclared) unless other code of the program built the same cell. Pre-existing since
  E2. Cases `listflags_*` and `listport` in `effects_e3.py`. Probed without failure (each in a program of its own, both modes):
  List of Int, Float, Bool, (), String, Json.Value, tuples, records, Arrays, `List (List String)`; Maybe of String, Float, records,
  tuples, Lists; Array String; a List inside a tuple or a record.
- **N2 header text:** `runtime/fic_ports_api.h` now warns about writes through the `fic_hv_string_alloc` pointer after sealing and
  about callbacks that send their borrowed value without `fic_hv_retain`.
- **Open, not fixed here:**
  - **F2 (to E3c/E3d): very deep values.** `fic_hv_to_json` and the error walker reach `fic_json_put`'s `exit(1)` beyond
    `FIC_JSON_MAX_DEPTH` (a value built through the API has no depth limit), against D7's "nothing here exits"; and the text of a
    refused value grows with the square of its depth (10,000 levels: a 400 MB `fic_port_error()` text). Suggested: `fic_hv_to_json`
    returns NULL when too deep; the error text stops at a byte budget with `...` (a deviation to record).
  - **F3 (to E3e): a failed `fic_app_start` cannot be retried.** `fic_app_started` is set before the flags are decoded, so after
    `FIC_E_DECODE` (or `FIC_E_INVALID` for an unsealed builder) every later start is "started already". Also, before a start,
    `fic_port_subscribe`/`send` answer `FIC_E_NO_PORT`, where "the program has not started" would be clearer.

## 7. Proposed entries for the shared files (not applied)

Decisions: a DONE entry for E3a+E3b (this note's section 2, the binary, the gate results); the recorded deviations: crash 4's second
line is `errorToString` (confirmed: Elm's debug build prints `[object Object]`), absent `Json.Value` flags (and `Maybe Json.Value`)
refuse to start, a `{ length : .. }` record port refuses a JSON array; NOTE: unused ports are dead code in Elm (checked) and in Ficcus.
Checklist: E3a and E3b ticked; E3c to E3f open; "remove fic_sched.h's E2 port section" as a cleanup item for the next slice that may
change the C of scheduler programs.
