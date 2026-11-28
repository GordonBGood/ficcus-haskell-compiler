# E3c + E3d: Ficus payloads, raw vectors, very deep values (session notes)

Branch `feat/e3c` from ficcus af71a00e (T1c merged), binary `bin/elmficE3c`, identity reference `bin/elmficT1c`. Design:
`docs/E3-PORTS-DESIGN.md` D5, D6, D9, D10 (and D16 for the timing line); `docs/E3A-REVIEW.md` F2. The shared files are not edited
(section 7 has the proposed entries).

## 1. What was built

**Compiler (Haskell)**
- `Canonicalize.FicPayload` (new): the payload check of a `.fic` module of a build to C: Elm's set plus `Int8 Int16 Int32 Word8 Word16
  Word32 Word64`, `Float32` and `Vector a` (recognized by their overlay ids, as `Canonicalize.Derive` does). Every refusal is the one
  Elm's walk gives. Elm's `Canonicalize.Effects.checkPayload` is unchanged and stays the check of every `.elm` module and every build
  to JavaScript. The check is now a parameter of `Effects.canonicalize`; `Canonicalize.Module.canonicalizeWith`, `Compile.compileWith`,
  `Compile.compileTypedWith` carry a Bool, set by `Build.compile` when the file is `.fic` and the build is typed (C or `.mono`).
- `Optimize.Port`: a Ficus type is converted like its Elm look-alike (sized integer as Int, Float32 as Float, Vector as Array) in the
  JavaScript converters that a build to C keeps in its graph but never runs; it keeps the optimizer total and gives the manager order
  of the Elm twin (the twin cases compare that order too).
- `Ficus.Mono.PortFic` (new): the C pieces per type (encoder, range checked decoder, raw element kind, description character, header
  shape). `Ficus.Mono.PortDesc`: description characters `c h n C H N W g` and `V<T>`; `<Module>_ports.h` shapes. `Ficus.Mono.CGen`:
  branches for sized types, Vector (raw or array), Float taking a JUINT, Json.Value through `fic_pv_plain`.

**Runtime**
- `runtime/fic_ports_fic.h` (new, between `fic_ports_api.h` and `fic_ports.h`; only in programs with ports or flags):
  - `JUINT {u64}` (D5) and the raw vector node `HV_VEC {vec, n, elem, data[]}` (D9, D10), host side only;
  - `fic_hv_uint`, `fic_hv_get_uint`, `fic_hv_vector_alloc`, `fic_hv_vector_copy`, `fic_hv_vector`; range checked decoders
    (`fic_pv_int_in`, `fic_pv_u64_in`, `fic_pv_f32_in`) and their slow path texts (`fic_pv_explain_sized`);
  - Vector out (`fic_pv_vec_out`: the 8 byte kinds hold the program's Vector, zero copy; the narrow kinds are narrowed once into the
    node) and in (`fic_pv_vec_in`: the 8 byte kinds move the Vector; the narrow kinds widen the staging buffer in one pass);
  - F2: an iterative JSON writer with a byte budget (`fic_pv_put`), an iterative host JSON parser (`fic_pv_parse_value`, the leaves and
    rules of `fic_json.h`, JUINT for integer literals in (2^63 - 1, 2^64 - 1]), and the Json.Value conversion `fic_pv_plain`
    (iterative; walks only after some JUINT or raw node was ever made: `fic_hv_specials`).
- `fic_ports.h`: the new kinds in `sealed`, `kind`, `get_float`, `len`; `fic_hv_at` returns NULL for a raw vector (a test found it
  read the vector as an object); `fic_hv_from_json` and `fic_hv_to_json` and the error printer use the new walks; `fic_pd_explain`
  handles the new characters. `fic_ports_api.h`: `enum fic_el` and the new functions, documented. `runtime/fic_json.h` is unchanged,
  so every program without ports or flags keeps its C.

## 2. Deviations from the note

1. **JUINT never enters the program.** D5 has `Json.Encode.encode` print a JUINT's exact digits; here a JUINT inside a Json.Value
   payload becomes the double it parses to (as Elm), so `Json.Decode` and `Json.Encode` inside the program see only Elm's nodes and
   `fic_json.h` stays unchanged (identity of non-port programs). Exact digits exist on the host side: `Word64` payloads,
   `fic_hv_to_json`, `fic_hv_get_uint`.
2. **The host's JSON text has no depth limit** (its own parser; the program's `Json.Decode.decodeString` keeps L41's limit).
3. **F2:** `fic_hv_to_json` never fails at any depth (D7's "nothing exits"; no NULL needed). The text of a refused value stops after
   `FIC_PORTS_ERR_BUDGET` (1 MB) of printed value and ends with `...`; below that size the text is Elm's. Node itself stops at about
   10,000 levels ("Maximum call stack size exceeded").
4. **A raw vector node is taken only by a Vector port of the same element kind.** At a List, Array, tuple or non-numeric Vector
   position it is refused (the text prints it as an array: `Expecting a LIST`); a kind mismatch is refused with `Expecting a raw vector
   of WORD8 elements or an ARRAY`. No narrowing with range checks from another kind (D9 allows it "when the storage is wider").
5. **No seal for raw vectors:** `fic_hv_vector_alloc` returns a sealed value; the memory is not cleared (the host fills all n
   elements). Writing after the send is the same host error as N2 for strings (documented).
6. **Narrow kinds are narrowed by the encoder** (once, into the node), not lazily in `fic_hv_vector`.
7. **Range texts** (D7 says "Expecting an INT8"-style): `Expecting an INT8 (a whole number from -128 to 127)`, likewise for the others;
   `Float32` refuses only a non-number, with Elm's `Expecting a FLOAT`.
8. **The JS refusal** is the missing overlay module: a build to JavaScript has no `Int8`/`Vector` modules, and the existing Ficus hint
   says so (case `c_fic_js`). A project module of that name gets Elm's payload error.

## 3. Tests

`python3 ficus-tests/effects_e3c.py --elm B --elm-home H` (reuses `effects_e3.py`'s builds and checks: `--rc` gcc -O2, ASan + UBSan
without the pool, `-DFIC_DROP_ALL`, and `--no-rc`; live 0 and 0 bad, 0 live after the free): 7 runtime cases (28 checks) and 3
compile cases. Goldens: `--goldens --ref ../bin/elm0193`.

| Case | Kind | What |
|---|---|---|
| c_sized | twin | every sized type and Float32 at its edges, alone and in a record with Maybe, List, tuple |
| c_sized_crash | hand | runner, Int8 128: crash 4 with the range text |
| c_sized_edges | hand | API and text: Int8 -129 128, Word8 256 -1, Word64 2^63, 2^64 - 1, 2^64, -1, NaN, Float32 +-inf, 1e39, the rounding midpoint 2^128 - 2^103, FLT_MAX, records |
| c_vector | twin | Vector of Int, Float, Word8, Int16, Float32, Word64, String, records, Maybe (Vector Word8), in and out |
| c_vector_crash | hand | Vector Word8 [1, 256]: crash 4 at json[1] |
| c_vector_raw | hand | raw vectors of every kind; zero copy (`same`) for Int, Float, Word64; kind mismatches; JUINT and raw reads; 1 MB Word8 round trip checked byte for byte |
| c_deep | hand | 10,000 and 1,000,000 levels: to_json, from_json, send, send_json, Json.Value with a JUINT or raw leaf, List Int refusal (1 MB text) |
| c_elm_port_int8 | twin (report) | `.elm` module, port of the overlay's Int8: Elm's error text |
| c_fic_port_dict | twin (report) | `.fic` module, Dict: Elm's error text |
| c_fic_js | hand (report) | `.fic` to JavaScript with an Int8 port: refused |

Twin: the program with Array for Vector, Int for the sized integers, Float for Float32 (`twin()` in the script), inputs in range and
exact in JavaScript. Hand: checked line by line (examples: 2^128 - 2^103 rounds to infinity, ties to even; the 1 MB sum is 4096 x
32640; the Word64 fill steps by 2048, the spacing of doubles below 2^64).

Timing (informational, `--timing N`, gcc -O2 `--rc`, this machine, not idle): Vector Word8 round trip (host fill, send, widen, update
with the program's own `Vector.foldl` sum, dispatch, narrow, host check): 1 MB 6.5 ms, 100 MB 571 ms.

## 4. Gates

Targeted, serial, 2026-11-27, `bin/elmficE3c`, log `/home/gordon/claude-tmp/gates-e3c.log` (script `/home/gordon/claude-tmp/e3c/gates-e3c.sh`):
runtime 0; attach 378/0 `--rc`; types 267 PASS + 1 XFAIL; JS identity 28 identical; effects e1, e2, e3 all ok; effects_e3c all ok;
e1p all ok; a3b-identity against `bin/elmficT1c` 100 compared, 4 differ: E2Ports and E2PortsIn (`--rc`, `--no-rc`), the port programs,
by design (their C carries `fic_ports_fic.h` and the new decoder lines); rcgate-san 16 ok; suite 16/16 PASS. Not run: sized,
stringdiff, examples, fbip, e1review, e1pr, e1p-identity, rcfaults, rcfaults-big, typed, lib, elmdiff.

## 5. Open points for the Opus review (E3c + E3d)

1. **Lifetime of the 8 byte raw vectors:** in, the decoder dups the Vector out of the node and `send` releases the node (unique when
   the host did not retain it); out, the node holds a count on the program's Vector, so while the host retains it the program's next
   in place write copies. The host's `fic_hv_vector_alloc` pointer of an 8 byte kind IS the program's memory after the send.
2. **Staging buffers:** a narrow kind's staging buffer is freed with its node after the send; its address may come back for another
   object (the test host records only 8 byte allocations for its `same` check).
3. **`fic_hv_specials`** only grows: after the first JUINT or raw node (an outgoing Vector counts), every Json.Value payload is walked
   once (iterative, O(size)). A count of live special nodes would need a hook in the generic free.
4. **Recognition by id:** `PortFic.sizedOf`/`vectorElem` match the overlay ids without `Sized.sizedEnabled`; a project module `Int8`
   that wins over the overlay and is used as a `.fic` port payload would get the sized converter (wrong C). The C generator could test
   the marker constructor as `Sized.sizedEnabled` does.
5. **Float32 rounding** of an out of range double relies on IEEE conversion (`(double)(float)d`), as `Float32.fromFloat`.
6. **Flags of a Ficus type** stay refused (Elm's BAD FLAGS); `Build.compileOutside` (a root file outside the source directories) keeps
   Elm's payload check. Both could take the same gate.
7. **Raw nodes at List/Array positions** are refused rather than converted (deviation 4).

## 6. Commits

31dd97d3 (WIP: compiler and runtime), 8b967d25 (tests; `fic_hv_at` fix; Word64 like Int in Optimize.Port), 787a5c18 (report
normalization), the next commit (these notes, gate results).

## 7. Proposed entries for the shared files (not applied)

- Decisions file, E3: DONE E3c + E3d (date): Ficus payloads at ports (sized integers range checked, Word64 via JUINT on the host side
  only, Float32 rounded, Vector as array or raw vector with zero copy for 8 byte kinds and staging for narrow kinds), F2 fixed
  (iterative host walks, 1 MB error text budget); deviations 1 to 8 of `docs/E3C-NOTES.md`; open points for the Opus review.
- Checklist: tick E3c and E3d (pending review); note "G30 makes the D10 staging zero copy".
