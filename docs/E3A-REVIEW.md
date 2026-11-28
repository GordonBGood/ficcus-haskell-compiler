# E3a/E3b review: the ports value API and flags (soundness)

27 Nov 2026, branch `review/e3a` from `feat/e3a` e43c5ba1, binary `bin/elmficE3a`. Read: `docs/E3A-NOTES.md` sections 1 and 6,
`runtime/fic_ports_api.h`, `runtime/fic_ports.h`, D1 to D3, D7, D11, D12 of `E3-PORTS-DESIGN.md`, and the CGen parts they lead to
(the `#undef` wrapper, `portDecBody`, `appStart`). Reproducers in `ficus-tests/e3ar/` (`run.sh <elmfic> <elm-home> <scratch>`).

**Recommendation: merge after F1** (one missing line, pre-existing since E2, now also reachable through flags). No memory safety
problem was found: every ownership and re-entrancy case is clean under `--rc` with ASan and UBSan, live 0, `FIC_DROP_ALL` 0 bad.

## Must fix before merge

**F1. A `List String` payload does not compile** (incoming port or flags). Generated C: `unknown type name 'fic_o_pp'`. The List
branch of `portDecBody` (CGen.hs) calls `allocObj [boxedClass ec, CRef]` without `needObj`; the Array branch has `needObj afcs`. It
compiles only when the program builds such a cons cell elsewhere, which is why E3Errors and R1Own pass. Pre-existing: `elmficE2g` and
`elmficA4bf` fail the same way; E3b adds the flags route. Reproducers: `e3ar/src/R3PortList.fic`, `R3FlagsList.fic`
(`Program (List String) () ()`). Add one of them to `effects_e3.py`. Probably the same for any element class whose cons cell is
otherwise unused (List Float, List of a record); the fix covers them all.

## Fix later

**F2. Deep values break D7's "nothing here exits" and the error text is quadratic.**
(a) `fic_hv_to_json` and the error walker call `fic_json_put`, which calls `exit(1)` beyond `FIC_JSON_MAX_DEPTH` (1,000,000; 2,000
without the big stack). `host/deep.c`, `DEEP_MODE=tojson DEEP=1000001`: the host's process ends. A value built with the API has no
depth limit (only the parser has).
(b) A refused value is printed with indent 4 inside `indent`: the text grows with the square of the depth. `DEEP_MODE=refuse
DEEP=10000` gives a 400 MB `fic_port_error()` text (0.8 GB RSS); 1,500,000 levels ran past 60 s. Through `fic_port_send_json` a
100 KB text of 50,000 brackets would need about 10 GB. Elm does not get there: node's `JSON.stringify` throws "Maximum call stack size
exceeded" at 10,000 levels (it manages 3,000: 36 MB, same as Ficus). Suggest: `fic_hv_to_json` returns NULL when too deep; the
error path stops encoding at a byte budget (say 1 MB) and appends `...`, a recorded deviation. Release of a 1,500,000 deep tree is
fine (no recursion problem).

**F3. A failed `fic_app_start` cannot be retried.** `fic_app_started = 1` is set before the flags are decoded, so after
`FIC_E_DECODE`, or `FIC_E_INVALID` for an unsealed builder (a host bug, nothing ran), every later start is "started already".
`host/flags.c` modes `retry` and `unsealed`. Elm cannot retry either (init throws), but a C host that reads flags from a user would
want to. Suggest: set the flag after a successful decode (init has not run, nothing to undo; the partial decode is already released,
see N2). Related: before a start, `fic_port_subscribe`/`send` return `FIC_E_NO_PORT` ("there is no outgoing port `outS`"), which is
misleading; `FIC_E_INVALID` with "the program has not started" would be clearer.

**F4. More field names that JavaScript's `in` finds on every object.** Besides the known `length` on arrays, `constructor`
(and `toString`, `valueOf`, `hasOwnProperty`, `__proto__`, ...) is found on `{}` and `[]`. Elm: `{ constructor : Int }` given `{}`
fails at `json.constructor` with the value `undefined` and "Expecting an INT"; `{ constructor : Json.Value }` given `{}` is
**accepted** (a function enters the program and encodes as `undefined`). Ficus refuses both with "Expecting an OBJECT with a field
named `constructor`". Both Ficus decoders agree (no internal text). Suggest: record it with the `length` corner as one deviation
("a record field is an own key of a JSON object"). Reproducer: `pCtor`, `pCtorV` lines of `mklines.py`.

## Notes

**N1. Fast decoder and walker agree.** 91 lines (`mklines.py`) through `host/drive.c` against `ref/drive.js` on elm0193 + node:
not one `internal:` text. Every text and every accepted value equals Elm's except: L21 (`9223372036854775808` and `1e300` refused;
`9007199254740993` exact where Elm rounds), L11 (`String.length "aé😀"` is 3, Elm 4), and F4. Covered: record field order
with fields of 1 to 3 letters, missing and wrong fields, non-objects, Unicode field names (`['café']` quoting, ASCII `isAlpha` as
Elm), lone surrogates (U+FFFD in both), `\u0000`, `-0`, `1.0`, `1e400` as Float (Infinity) and Int (refused), `5e-324`,
`Maybe (Maybe Int)` oneOf texts, nested Arrays with an inner failure, tuples with extra entries and objects with keys "0", "1",
32,800- and 32,799-element Arrays failing at the last element, 2,000-deep values. The Int test is the same expression in
`portDecBody` and `fic_hv_int_of` (NaN and the infinities refused in both). One L21 edge (shared with `Json.Decode.int`, not new):
`-9223372036854775809` is parsed as the double -2^63 and accepted as -9223372036854775808, while `9223372036854775808` is refused; L21
says "fails beyond". Worth a line in L21 or a check of the literal in the parser.

**N2. Ownership (D3) holds; two gaps in the header's text.** `host/own.c` under ASan + UBSan, `--rc`: failures after partial work
(record `xs[2]`, missing field, tuple `[1][1]`, Array element 39 of 40) leave live 0; send of an unsealed builder or string, unset
slot, out of range, duplicate key, bad UTF-8 key, a retained builder (refused under `--rc`), NULL, unknown and wrong direction ports
all consume their value; a retained `"abc"` stays `"abc"` while `update` appends to it. Re-entrancy (D12): a callback sends (nested
update), subscribes another callback (called for the same value, as Elm), unsubscribes itself, retains its value and sends it back
retained; the value is released by a later callback. Without counts the output is the same except the shared builder, as documented.
Header gaps: (1) the pointer of `fic_hv_string_alloc` must not be written after `fic_hv_string_seal`: the sealed string moves into
the program at send, so a late write changes a program value; (2) a callback that passes its borrowed value to `fic_port_send`
without `fic_hv_retain` drops a count it does not own (a double free later). Both are host errors; say so in `fic_ports_api.h`.
Also, without `--rc` a retained builder still aliases the array that `finish` sealed: a later `array_set` through it writes into a
sent value (documented as undetectable; worth one sentence).

**N3. The `#undef FIC_TAG_JNULL` wrapper.** Only `fic_sched.h` lines 741 to 846 test the macro, and it is redefined right after
`schedRuntime`, before `fic_ports.h` and the body; programs with scheduler, ports and Json (R1Own, R2Text) build and run. It does
change a program without ports when `usesPorts`' text test fires on something else: `src/R4NoPorts.fic` (Time.every, a string
literal `"fic_app_start"`, no ports) gets the `#undef` and 963 lines of the ports runtime compared with `elmficA4bf`; it still
compiles and prints the same. The same kind of false positive already exists for `usesSched`. Suggest at the next change of
`fic_sched.h`: guard its E2 section with its own macro (`FIC_SCHED_E2_PORTS`) and decide `usesPorts` from `iMgrs`/`workerFlags`
instead of the text.

**N4. Array depth is right.** Elm's depth changes where `32 * leaves - 1` reaches a power of 32: at n = 64 (depth 1), 1,056 (2) and
32,800 (3), not at 32, 1,024 and 32,768. 25 sizes from 0 to 33,825 around all of these (63/64, 1,055/1,056, 32,799/32,800/32,801,
33,823 to 33,825), each checked against Elm with `==` to `Array.fromList`, `push`, `get` at 15 indices, `set`, `slice` and `foldl`:
all equal. `floor(log(32L-1)/log 32)` cannot round across an integer before about 2^50 elements. Elm decodes with
`Array.initialize`, whose shape equals `fromList`'s.

**N5. Flags (D11).** Checked against run3.js: absent flags (crash 2 with `undefined`), a failure after partial work (`json.b[1]`),
a non-object, a missing field: identical texts and exit 1; partial work released (live 0). `FIC_FLAGS` and `FIC_FLAGS_FILE` both set:
refused; an empty `FIC_FLAGS` counts as unset (as run3.js); missing file, a directory, bad UTF-8 and trailing text: a message and
exit 1. `Maybe Json.Value` flags absent: Elm gives `Just undefined`, Ficus refuses with its D11 text; the recorded deviation should
say it covers `Maybe Json.Value` too.

## Proposed entry for the shared files (not applied)

- **NOTE (27 Nov) E3a/E3b review (`review/e3a`, `docs/E3A-REVIEW.md`):** no ownership or re-entrancy fault (ASan, UBSan, live 0);
  fast decoder and error walker agree on 91 Elm twin cases; Array depth right to 33,825. Must fix: F1 `List String` port/flags
  decoder lacks `needObj` (pre-existing since E2). Later: F2 deep values (`exit` in `fic_hv_to_json`, quadratic error text), F3 a
  failed start cannot be retried, F4 record fields found by JavaScript's `in` (`constructor`) as a deviation with `length`.
