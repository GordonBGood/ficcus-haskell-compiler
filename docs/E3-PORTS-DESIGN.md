# E3 ports: the host interface (design note)

Design session (Opus 5.5), 26 Nov 2026, branch `design/e3` from `ficcus` `75e3ed9a`. Read only: no code, nothing built or run, no
shared doc edited. Proposed entries for the shared files are in section 10.

**Marks.** **[S]** read in the source named. **[A]** assumption or inference, not checked. A sentence without a mark is argument.

**Read:** `docs/EFFECTS-DESIGN.md` (D-fx-1 to 11 with the E1/E2 amendments), `docs/EFFECTS-CHECK.md` (on `design/fx-check`),
`docs/E1-REVIEW.md`, `docs/E2-REVIEW.md`, `docs/E1P-DESIGN.md` (summary), `runtime/fic_sched.h` (ports, loop, teardown),
`runtime/fic_json.h`, `fic_vector.h`, `fic_sized.h`, `fic_string.h`, `fic_rt.h` (`fic_alloc`), `Ficus/Mono/CGen.hs`
(`portEncode`, `portEncBody`, `portDecBody`), `Ficus/Mono/Spec.hs` (`specWorker`, the flags refusal), `Optimize/Port.hs`, elm/core
1.0.5 `Elm/Kernel/{Platform,Debug}.js`, and the decisions of 25 Nov: ports payloads and host API (decisions line 604) and FFI layer 1
(line 605).

---

## 1. Starting point

What E2 left [S: `fic_sched.h` lines 693-845, `CGen.hs` 1847-2060]:

- A port is a runtime manager in Elm's table order. Outgoing: `init = sleep 0`, `onEffects` delivers the list (batch reversed) and
  sleeps 0 again, so delivery is asynchronous, as in Elm. Incoming: `onEffects` keeps the subscriptions; `fic_port_send(name, json)`
  borrows a JSON tree, runs the generated decoder `fic_pdec_*` and calls `sendToApp` once per subscription, at once.
- The **value tree is `Json.Value` itself** (`fic_json.h`): static null and booleans, `JINT {int64}`, `JFLOAT {double}`, the string
  object, a `JsArray` of references, `JOBJ {keys, vals}` in JavaScript's key order (L35). The outgoing encoder runs **when the command is
  made** (the leaf holds the tree), as Elm's `outgoingPort` converter does when it builds the leaf.
- Converters cover Int, Float, Bool, String, `Json.Value`, (), Maybe, List, tuples, records (fields in Elm's `Map.toList` order:
  length, then bytes). Not: `Array`, `Vector`, sized integers, flags (a compile error since the E2 review).
- Decoders return only success or failure (`int`); a failure prints the first line of Elm's crash 4 and exits 1. The single subscriber
  is the test runner (`<port>: <JSON>`, `output` as text) and the only input is `FIC_PORTS_IN`.

Facts that shape the design:

- A Ficus `String` holds its bytes **inline** (`{hdr, len, cps, data[]}`, NUL terminated) [S: `fic_str_new`], and so does a `Vector`
  (`{hdr, esize, spare, len, cap, desc, data[]}`) [S: `fic_rt.h:260`]. Nothing in the runtime can point at a buffer it did not allocate.
- Sized integers and `Float32` occupy the **8 byte slot** of Int/Float, also as `Vector` elements [S: `SIZED-PLAN.md` line 23];
  natural width storage is G30/H24 (open). A `Vector Word8` of n bytes is 8n bytes today.
- Objects above the pool's largest class are `malloc`ed (`cls 0`) [S: `fic_alloc`]; the pool, the live counters and the counts are
  single threaded (D-fx-10).
- Elm's incoming port does **not** crash the program on a bad value: `send` throws a JavaScript exception before `sendToApp`, the
  program state is untouched, and a host can catch it [S: `_Platform_incomingPort`, `__Debug_crash(4, name, result.a)`]. Only the
  test runner, which does not catch, exits 1.
- Elm's flags decoder is `Json.Decode.succeed ()` for `()` (any flags, even none, are accepted) and the port decoder otherwise; a failure
  is crash 2, `Problem with the flags given to your Elm program on initialization.\n\n` + `errorToString` [S: `Optimize/Port.hs
  toFlagsDecoder`, `Debug.js`]. Missing flags reach the decoder as JavaScript `undefined` [S: `args ? args['flags'] : undefined`].
- Elm's crash 4 in debug mode is `'Trying to send an unexpected type of value through port `' + name + '`:\n' + problem` where
  `problem` is the `Json.Decode.Error` **value**, not its text [S]; concatenating an Elm custom type value in JavaScript gives
  `[object Object]` [A: not run]. With `--optimize` the message is the hint URL `.../hints/4.md` [S: `_Debug_crash__PROD`].
- Elm's port set is the set of **reachable** ports: an unused `port` declaration is dead code and absent from `app.ports` [A: from the
  JS generator's dependency walk; not run].

---

## 2. The C host API (item 1)

### D1. The value representation the host sees

**Recommend: the host value is `Json.Value`, i.e. the existing `fic_json.h` tree, behind an opaque handle `fic_hv` (a `fic_ref`)**,
plus one node kind for raw numeric vectors (D9) and one for unsigned 64 bit integers (D5). The generated type directed converters stay
the only place that knows port types; the host deals in seven kinds. A `Json.Value` payload passes through untouched (a count, no
walk), which is exactly Elm's `identity` encoder and `Json.Decode.value` decoder.

Alternatives: (b) **typed C structs per port** (a generated `struct inn_payload { int64_t id; fic_str name; ... }` and
`fic_port_send_inn(const struct inn_payload *)`): no tree, the fastest for flat records, but recursive payloads (a `List` of records)
need builders anyway, every port type change changes the host's C, and the generated header becomes a second ABI to keep stable.
Keep it for the F1 layer 2 note (typed `extern`). (c) A streaming visitor (SAX style): lowest memory, but the decoder must then accept
fields in any order and the host code is awkward. Section 8 says when (b) would pay.

### D2. The function set

Kept as small as the seven kinds allow. All functions are **loop thread only** except the two in D14.

```c
typedef struct fic_hdr *fic_hv;                     /* opaque; NULL never denotes a value */
enum fic_hv_kind { FIC_HV_NULL, FIC_HV_BOOL, FIC_HV_INT, FIC_HV_FLOAT, FIC_HV_STRING,
                   FIC_HV_ARRAY, FIC_HV_OBJECT, FIC_HV_VECTOR };    /* FIC_HV_INT includes the unsigned node of D5 */

/* build (each returns an OWNED value, count 1) */
fic_hv fic_hv_null(void);  fic_hv fic_hv_bool(int b);
fic_hv fic_hv_int(int64_t i);  fic_hv fic_hv_uint(uint64_t u);  fic_hv fic_hv_float(double d);
fic_hv fic_hv_string(const char *utf8, size_t n);          /* copies; NULL if not valid (D4) */
fic_hv fic_hv_array(size_t n);   int fic_hv_array_set(fic_hv a, size_t i, fic_hv v);          /* consumes v */
fic_hv fic_hv_object(size_t n);  int fic_hv_object_set(fic_hv o, size_t i, const char *key, size_t kn, fic_hv v);
fic_hv fic_hv_finish(fic_hv v);  /* seals an array or object (object: L35 key order, last duplicate wins); required before send */

/* read (borrowed results, valid while the host holds the value) */
enum fic_hv_kind fic_hv_kind(fic_hv v);
int fic_hv_get_bool(fic_hv, int *); int fic_hv_get_int(fic_hv, int64_t *); int fic_hv_get_uint(fic_hv, uint64_t *);
int fic_hv_get_float(fic_hv, double *);
const char *fic_hv_get_string(fic_hv v, size_t *n);        /* UTF-8, NUL terminated */
size_t fic_hv_len(fic_hv v);                                /* array, object, vector */
fic_hv fic_hv_at(fic_hv v, size_t i);                       /* array element or object value */
const char *fic_hv_key(fic_hv o, size_t i, size_t *n);
fic_hv fic_hv_field(fic_hv o, const char *key);             /* NULL if absent */

/* counts */
fic_hv fic_hv_retain(fic_hv v);  void fic_hv_release(fic_hv v);

/* ports */
typedef void (*fic_port_fn)(void *env, fic_hv v);           /* v borrowed for the duration of the call */
int  fic_port_subscribe(const char *port, fic_port_fn fn, void *env);
int  fic_port_unsubscribe(const char *port, fic_port_fn fn, void *env);
int  fic_port_send(const char *port, fic_hv v);             /* consumes v */
const char *fic_port_error(void);                           /* text of the last failure, until the next call */
```

Each `int` result is `FIC_OK` (0) or a negative code (D7). The generated program also emits `<module>_ports.h` with one comment line per
reachable port giving its Elm type and its JSON shape, and `#define` constants for the port names, so a misspelt name is a compile
error in the host.

Alternatives: a smaller API without typed getters (host walks with `kind` + one `fic_hv_number`): saves six functions, loses the
Int/Float distinction the tree already has. A larger one with per kind iterators: not needed, `len` + `at` are O(1).

### D3. Ownership at the boundary

**Recommend: `send` consumes, callbacks borrow, `retain`/`release` for anything kept.**

- `fic_port_send` **consumes** its value. The decoder then *moves* leaves (strings, vectors, `Json.Value` subtrees) into the Ficus
  value instead of adding counts, so a 64 MB vector or string arrives in `update` with count 1 and `update` can write it in place
  (the D-fx-3 protocol and E1p's per leaf move keep it unique when it is stored in the model). A host that wants to keep the value
  calls `fic_hv_retain` first, and pays the copy at the first in place write: correct, slower, the same rule as everywhere (the count is
  the truth).
- Builders consume what they store (`array_set`, `object_set`), like the runtime's kernels.
- An outgoing callback gets a **borrowed** value, valid until it returns. To keep it (an async host, a batching writer), `retain` it and
  `release` later on the loop thread. While the host holds a count the Ficus side cannot write that object in place, so the host's view
  is immutable; no copy and no lock are needed.
- `fic_hv_release` of the last count frees on the loop thread; under `--rc` a value still retained at shutdown is a live object and is
  reported, as any leak (D15).

Alternative: `send` borrows (E2's internal convention). Costs one count per leaf and makes every received string or vector shared
(copy on first write) unless the host releases before `update` runs, which it cannot, since `send` runs `update` synchronously.

### D4. Strings

**Recommend: UTF-8 in both directions; `fic_hv_string` copies once and validates with the same rule as the JSON parser; a zero copy
builder for large text.** The inline layout makes a borrowed host buffer impossible without a new string representation, which every
string kernel would have to test. For large text: `fic_hv_string_alloc(n, &p)` returns a writable buffer inside a new string object,
and `fic_hv_string_seal(s)` validates and computes the code point count (`cps`); an invalid sequence makes `seal` fail and release.
Outgoing: `fic_hv_get_string` gives the object's own bytes, borrowed (zero copy). Lone surrogates: whatever `fic_json_parse_string`
accepts for `\uD800` escapes is accepted, raw bytes outside that rule are refused [A: the internal encoding of lone surrogates was not
re-read for this note].

Alternatives: accept any bytes (cheaper, but then a Ficus `String` can hold what Elm cannot, and `String.length` disagrees with Elm);
UTF-16 at the boundary (matches JavaScript, doubles the conversion cost for a C host that has UTF-8).

### D5. Numbers, sized integers and range checks

**Recommend:**

- `Int` and `Int64`: `JINT` exact (L21). Incoming `Int` accepts a `JFLOAT` that is integral and in range, as E2 does (JavaScript
  numbers `1.0`, `1e3` are ints to Elm).
- Narrow sized types: the decoder checks the range of the type and fails as a decode failure ("Expecting an INT8"-style text, D7),
  never wraps (decided 25 Nov). The check is one compare pair against a conversion that already reads a node.
- **`Word64`**: a new node kind `JUINT {uint64}` produced only by `fic_hv_uint` with a value above `INT64_MAX`, by the `Word64`
  encoder for such values, and by the JSON text adapter (D8) for integer literals in `(2^63-1, 2^64-1]`. Every existing consumer treats
  `JUINT` as the double it would have parsed to (`Json.Decode.float` gives the rounded value, `Json.Decode.int` fails), so `Json.Decode`
  results do not change; `Json.Encode.encode` prints the exact digits, extending L21 from `int64` to `uint64`.
- `Float`: any number. `Float32`: rounded with `(double)(float)` as `Float32.fromFloat`; out of range gives an infinity, not a failure.
- NaN and infinities: the value API carries them; the text adapter writes `null` (L20, JSON.stringify).

Alternatives for `Word64`: as a decimal string (portable, but a type change visible to JavaScript hosts); as a double (rounds every
value above 2^53, which the `Word64` type is meant to avoid). The JS build is unaffected: a `Word64` port is refused there (decided).

### D6. Payload types: records, custom types, Maybe, Dict, Array, Vector

**Recommend Elm's set plus the decided additions, nothing more:** Int, Float, Bool, String, (), `Json.Value`, Maybe, List, `Array`
(new in E3, the same JSON as List), tuples, records, `Vector` (any approved element), sized integers, `Float32`. **Custom types and
`Dict` stay refused**, as Elm's `Canonicalize.Effects.checkPayload` refuses them; the route for them is a `Json.Value` port with the A4
derived `encode`/`decoder` members. Maybe: `null` or the value, so `Maybe (Maybe a)` cannot express `Just Nothing`, as in Elm (its
decoder is `oneOf [null Nothing, map Just d]`). Records: a JSON object, extra fields ignored, missing ones a failure; outgoing fields in
Elm's order (E2). The `.fic` extension of `checkPayload` is gated: an `.elm` module keeps Elm's error text exactly, and the JS build of
a `.fic` program with a Ficus only payload is refused (decided).

Alternative: allow custom types with a fixed encoding (`{"tag":..,"args":[..]}`). Not Elm's, not stable under constructor reordering,
and A4 already gives the user a chosen encoding.

### D7. Errors

**Recommend: the host API never exits; it returns a code and a text, and the test runner turns a failed send into Elm's crash.**

- Codes: `FIC_E_NO_PORT` (no reachable port of that name and direction), `FIC_E_DECODE` (the value does not fit), `FIC_E_INVALID`
  (a bad handle or an unsealed array/object), `FIC_E_STOPPED` (after teardown, D15), `FIC_E_THREAD` (debug builds: called from another
  thread).
- `fic_port_error()` gives, for `FIC_E_DECODE`, **Elm's `Json.Decode.errorToString` of the error Elm's decoder would give**. The fast
  decoder only says yes or no, so on failure only, the runtime runs the slow path: it builds the decoder of `Optimize.Port.toDecoder`
  from a static type description (`fic_jd_*` nodes: `oneOf [null, map Just]`, `index`/`andThen`, `field`), runs `fic_jd_run`, and
  calls the compiled `errorToString`. Success never pays; the text equals Elm's because the decoder tree and the error printer are Elm's
  own (field order of the record decoder: Elm folds over `Map.toList`, so the first missing field reported is the first in Elm's order).
- The runner (`FIC_PORTS_IN`) on failure prints Elm's crash 4 line and exits 1, after flushing stdout, as now. The second line is
  `errorToString` (E2 review option 4) where Elm in debug mode prints `[object Object]` [A]: stderr is not compared, record it as a
  deviation. A send to an unknown port in the runner keeps E2's message and exit 1 (node: a TypeError on `app.ports.x.send`).

Alternative: exit on any decode failure as E2 does. That is the runner's behaviour, not Elm's: an embedding host could not reject bad
input without dying.

---

## 3. The JSON text adapter (item 2)

### D8. Text as a thin layer over the value API

**Recommend:**

```c
int fic_port_send_json(const char *port, const char *text, size_t n);   /* parse, then fic_port_send */
char *fic_hv_to_json(fic_hv v, size_t *n);                               /* JSON.stringify; malloc'd, host frees */
```

`send_json` = `fic_json_parse` (with the `JUINT` rule of D5) then `fic_port_send`; a parse failure is `FIC_E_DECODE` with the text of
JavaScript's `JSON.parse` error replaced by Elm's (`errorToString` of `Failure "This is not valid JSON! ..."`, the text
`Json.Decode.decodeString` gives) [A: which text a JS host shows depends on where it parsed; the decode text is the one Elm owns].
`to_json` is `fic_json_encode 0` (JSON.stringify, L20 for NaN), with a raw vector node (D9) written as an array of numbers. The E2
runner is rebuilt on these two functions plus `fic_port_subscribe`, so it stops being a special path; its output format is unchanged
(`<port>: <JSON>`, `output` as text). `Json.Value` flows through unchanged both ways: parsed once into the tree, which becomes the Elm
value by a move.

Alternatives: a type directed parser that builds the Ficus value straight from text without the tree (faster for large lists of
records, about half the allocations [A]); decide after the measurement (section 8). A separate `fic_port_subscribe_json` callback form:
not needed, `to_json` inside the callback does it.

---

## 4. The raw `Vector` fast path (item 3)

### D9. Raw numeric vectors

**Recommend: a `Vector` of a fixed width number crosses as the vector object itself, never as an array of number nodes.**

- **Outgoing:** the encoder of `Vector Int`, `Vector Float`, `Vector Word8` and the other sized element types puts the vector object in
  the tree (kind `FIC_HV_VECTOR`, a count, O(1)). The host reads `fic_hv_vector(v, &elem, &len)` → `const void *data`, borrowed; to keep
  it, `retain` (D3). Zero copy whatever the size.
- **Incoming:** `fic_hv_vector_alloc(elem, n, &data)` returns a new, unique vector with a writable data pointer; the host fills it
  (`read(2)`, `fread`, a decompressor) and sends it; the decoder checks the element kind against the port type and moves the object into
  the value. Zero copy. `fic_hv_vector_copy(elem, ptr, n)` is the one `memcpy` convenience.
- `elem` is one of `FIC_EL_I8 .. FIC_EL_U64, FIC_EL_F32, FIC_EL_F64`. Incoming narrow kinds are range checked element by element only
  when the storage is wider than the kind (it is today, see D10); a natural width buffer cannot hold an out of range value.
- A vector of records or strings is not raw: it crosses as an array of nodes.
- A raw node inside a **`Json.Value`** payload (a host that put one into a tree for a `Json.Value` port) is converted to an array of
  number nodes by the decoder, because Elm code may walk it with `Json.Decode`; `Json.Decode` never sees a vector node.

Alternatives: (b) a **borrowed host buffer** inside a Ficus vector (an "external data" vector with a destructor): true zero copy for a
buffer the host did not let Ficus allocate (an mmap'd file), but every inline vector access (`FIC_VECTOR_AT`) would need an
indirection or a second tag test; rejected for the hot loops' sake, revisit with the F1 note (opaque handles with destructors are the
better tool for mmap). (c) Always copy: simple, costs a `memcpy` per crossing.

### D10. `Vector Word8` before natural width storage

**Recommend: ship the API now with 8 byte storage behind it; make it zero copy when G30 lands, without an API change.** Today a byte
vector is 8 bytes per element, so `fic_hv_vector_alloc(FIC_EL_U8, n, &p)` cannot hand out the vector's own memory. Until G30:
`vector_alloc` for a narrow kind returns a staging buffer (a malloc'd block kept beside the handle), and `fic_port_send` widens it into
the vector in one pass (no range check needed: a `uint8_t` cannot be out of range); outgoing, `fic_hv_vector` narrows into a buffer
owned by the handle, freed with it. The `retain` rule makes the narrowed copy valid for as long as the host holds the value. Cost until
G30: one pass at memory speed and 9n bytes peak instead of n.

Alternatives: do G30 first and make E3d wait for it (cleaner, delays the byte path); expose the 8 byte layout to hosts (an ABI that will
change).

---

## 5. Flags (item 4)

### D11. Flags on the C path

**Recommend:**

- The worker accepts any port-able flags type. The stepper's `init` call takes the flags value decoded by Elm's flags decoder
  (`succeed ()` for `()`, else the port decoder of D7), moved in (owned).
- **Where flags come from:** embedding: `fic_app_start(fic_hv flags)` (consumed; `NULL` means absent); the standalone executable:
  `FIC_FLAGS='<json>'` or `FIC_FLAGS_FILE=<path>` (one of them; the file wins if both, or refuse both, D11 detail for the user), parsed
  with the D8 adapter. No command line syntax is claimed: `argv` belongs to the program once a `Console`/process module exists.
- **Absent flags** are JavaScript `undefined`: a static node `JUNDEF` that every decoder rejects, whose text in `errorToString` is
  `undefined` (as JSON.stringify gives to Elm's `indent`), so `Program Int` started without flags fails with Elm's exact text. `()`
  flags accept anything, also absent, as Elm. A `Json.Value` flags type started without flags would pass `undefined` into the program in
  Elm; Ficus refuses to start instead (a recorded deviation: `JUNDEF` must never enter a `Json.Value`).
- **Failure:** crash 2, the text `Problem with the flags given to your Elm program on initialization.\n\n` + `errorToString`, stdout
  flushed, exit 1, before `init` runs. `fic_app_start` returns `FIC_E_DECODE` with the same text instead of exiting.
- `Browser.*` programs (later) reuse the same entry.

Alternatives: flags from the command line (`--flags`): conflicts with the program's own arguments later; flags as JSON text only
(no value form): a C host would print and reparse its own data.

---

## 6. Scheduler, teardown, threads (item 5)

### D12. Re-entrancy: what a callback may do

**Recommend: Elm's rules, tested.** An outgoing callback runs inside the port manager's `onEffects`, inside a drain. It may call
`fic_port_send`: as in Elm (`sendToApp` is synchronous), `update` runs nested at once, and its effects queue behind the dispatch in
progress (`enqueueEffects`' guard, E2). It may `subscribe`/`unsubscribe`: the delivery loop works on the list of the moment (Elm copies
`subs` before the loop [S]). It must not call `fic_run`/`fic_poll_once` (`FIC_E_INVALID`). `fic_port_send` from outside any drain (a
timer of the host, an fd callback) starts a drain and returns when the queue is empty, as a JavaScript event handler does. Model
uniqueness is unaffected: the stepper restores the model slot before any scheduler code runs (D-fx-3).

### D13. The embedding loop

**Recommend:** `fic_app_start(flags)` (init, first dispatch; does not block), `fic_run()` (the current `fic_sched_run`),
`fic_poll_once(timeout_ms)` (run due timers and posted work once, for host driven loops, D-fx-11 option c), `fic_app_stop()`. The
standalone `main` keeps today's end rule (no timer left: exit). An embedding host may keep the loop alive with no timer pending:
`fic_hold()`/`fic_unhold()` (libuv's ref/unref), so a program that only waits for incoming port messages does not end.

### D14. Threads (before T1)

**Recommend: everything above is loop thread only; exactly two functions are thread safe:**

```c
int fic_post(void (*fn)(void *env), void *env);                       /* runs fn on the loop thread, FIFO */
int fic_post_json(const char *port, const char *text, size_t n);      /* copies the text, then send_json on the loop thread */
```

A mutex protected queue plus an `eventfd`/self pipe that wakes the loop's wait (today a `nanosleep`; it becomes a `poll` on that fd
with the timer deadline, which E3e needs anyway). No Ficus object crosses a thread: another thread posts plain data (or a function that
builds the value on the loop thread). This needs no atomics, no change to `fic_alloc`, and is what D-fx-10 (b) and D-fx-11 (a, b)
assume. Large buffers from another thread: the host posts its own `malloc`ed buffer and the loop copies it into a vector (one
`memcpy`); a zero copy "detached vector" allocated off the pool by any thread and adopted by the loop is possible because large objects
are `malloc`ed already (`cls 0`), but it touches the live counters and the `FIC_DROP_ALL` registry, so it is left to T1.

What must stay single threaded: the counts, the pool, the scheduler, the manager table, every `fic_hv_*` and `fic_port_*` call.
Debug builds record the loop thread at `fic_app_start` and fail other callers with `FIC_E_THREAD`.

Alternative: make `fic_port_send` itself thread safe (lock around the scheduler). Wrong model: it would run `update` on the caller's
thread and make every count racy.

### D15. Teardown

**Recommend:** `fic_app_stop()` (or the natural end) runs `fic_platform_teardown` (E2) and then releases the subscriber table. Pending
outgoing messages are dropped on an explicit stop (a JavaScript page that closes drops them too); on the natural end there are none (a
queued message holds a `sleep 0` timer, E2 review Q7). Values the host still retains are the host's leak: under `--rc` they show as
live objects at shutdown. Every `fic_*` call after the stop returns `FIC_E_STOPPED`; `fic_post` after the stop drops the work and
returns it, so the host can free `env`.

---

## 7. Throughput measurement (item 6)

### D16. The benchmark

Program `ficus-tests/e3bench/` (one `.fic` worker with an incoming and an outgoing port per payload type, `update` echoing the payload
or folding it to a checksum) and a C host `bench_host.c`. Method of 19 Nov (the `PrimesBench` shape): timing inside the host with
`CLOCK_MONOTONIC` around a repeat loop only, repeat count from the command line, median of 5, serial, idle machine, `-O2
-ffp-contract=off`, `--rc`. Each case reports MB/s (payload bytes as the host holds them) and ns per message, and peak RSS.

| Case | Sizes | Paths | Direction |
|---|---|---|---|
| S small record `{id:Int, name:String, ok:Bool}` | 1 message, 10^6 repeats | value, text | in, out, round trip |
| S0 the same with 0, 1 and 3 other managers live | | value | in |
| L long `String` (ASCII; and 30% 2 to 4 byte UTF-8) | 1 MB, 64 MB | value (copy), value (`string_alloc`), text | in, out |
| R `List {id:Int, name:String, score:Float}` | 10^3, 10^5 records | value, text | in, out |
| VI `Vector Int`, VF `Vector Float` | 10^6, 8·10^6 elements | raw, value (array of nodes), text | in, out |
| VB `Vector Word8` | 1 MB, 64 MB | raw (with D10's widen/narrow), text | in, out |

References on the same machine: `memcpy` bandwidth for the same sizes (upper bound of a copying path); node 21 with Elm 0.19.3 for S,
L, R and `Array Int`/`Array Float` through ports (the JavaScript baseline, `app.ports.x.send` of a JS object, subscriber counting);
`JSON.parse`/`JSON.stringify` in node for the text path. Memory: `free -h` before each large case; the 64 MB cases need about 1 GB
(8 byte storage, text form, node).

**What counts as good** (proposed thresholds; the report states them against the results):

- raw out: O(1), under 1 µs at any size; raw in (8 byte kinds): at least 50% of `memcpy` bandwidth including the host's fill;
- value path: strings at least 1 GB/s (one copy plus UTF-8 validation); small round trip at most 2 µs, or the S0 numbers show the
  time is the dispatch (every manager gets an `fx` message per update, Elm's rule), not the conversion;
- text path: within 2× of node's `JSON.parse` + Elm decode for R and VI;
- no case slower than Elm under node.

---

## 8. Slices, reviews, gates (item 7)

| Slice | Content | Size [A] | Review |
|---|---|---|---|
| **E3a** | value API (D1–D4, D7), `Array` payloads, subscribe/unsubscribe, error texts via the slow decoder path, the generated `<module>_ports.h`, the runner rebuilt on the API | C 700, Haskell 300 | **Opus soundness** (ownership at the boundary, moves into the value, error path) |
| **E3b** | flags (D11): `JUNDEF`, `FIC_FLAGS`/`FIC_FLAGS_FILE`, crash 2, `fic_app_start` | C 150, Haskell 150 | with E3a's review |
| **E3c** | Ficus payloads (D5, D6): `Vector` of any approved element as arrays, sized integers with range checks, `Float32`, `JUINT`; `checkPayload` gate for `.fic` and the JS build refusal | Haskell 300, C 200 | **Opus** (range checks, the JS refusal, `.elm` error texts unchanged) |
| **E3d** | raw vector path (D9, D10) | C 300, Haskell 100 | with E3c's review (lifetime, staging buffers) |
| **E3e** | embedding loop and threads (D13, D14): `poll` wait, eventfd, `fic_post`, holds, stop | C 400 | Opus, together with T1 |
| **E3f** | benchmark and report (D16) | tests only | none |

Order: E3a+E3b, review; E3c+E3d, review; E3f on an idle machine; E3e after the T1 note (D14 is written so that T1 can change only the
"detached vector").

**Tests and gates.**

- Differential against Elm 0.19.3 under node (`ficus-tests/effects3/`, a node runner that subscribes and sends like the E2 harness):
  every payload type in and out; record field orders; `Maybe` nulls; Int given `1.0`/`1e3`; decode failures (stdout up to the failure,
  exit 1); an unknown port; flags of each type, absent flags, bad flags (exit 1, stderr text checked against Elm's crash 2, which is
  stable); a callback that sends synchronously (D12) and one that unsubscribes itself; `Array` payloads.
- Host API unit tests in C (`runtime/test_ports.c`, the `test.sh` pattern): ownership (send consumes, retain/release, a vector sent
  with count 1 arrives unique: `FIC_STATS` 0 vector copies in an `update` that writes it), errors and texts, after-stop calls,
  `fic_post` from a second thread under TSan.
- Ficus only payloads: no Elm twin; expected outputs written by hand and checked by a round trip (send, echo, compare) plus range
  edge cases (`-129`, `128`, `256`, `2^64-1`, `2^64`).
- Rejects: custom type and `Dict` ports (Elm's text, byte equal on `.elm`), `Vector`/`Word8` port in an `.elm` module and in the JS
  build of a `.fic` program.
- Every test under `--rc` live 0, ASan+UBSan, `FIC_DROP_ALL`.
- **Elm programs stay byte identical:** JS identity (28 of 28) against `bin/elm0193` (the `checkPayload` change must not touch the `.elm`
  path), `elmdiff` 1,175 SAME, the 16 suite programs' C text identical to the previous binary in both modes (no ports there),
  `effects_e2.py` and `e2_review.py` unchanged outputs (the runner rewrite must print the same lines), then the full `gates.sh`.

---

## 9. What this note cannot decide without a measurement (item 8)

1. **Tree vs typed structs (D1 b).** If R (lists of records) through the value path is far below the text path of node or spends most
   of its time allocating nodes, a generated typed path pays; otherwise not. E3f decides.
2. **Type directed text parsing (D8 alternative).** Only if the text path misses the 2× threshold on R or VI.
3. **Whether small messages are dominated by the dispatch.** Elm sends one `fx` message to every manager after every update; S0 shows
   the cost per manager. An optimisation (skip managers with no commands and unchanged subscriptions) would be an observable-order
   question, a separate decision.
4. **The cost of D10's widen/narrow** against making G30 a prerequisite of E3d.
5. **The real cost of the slow error path** (D7): irrelevant unless a host uses failure as a normal outcome (a filter); measure one case.
6. **Detached vectors across threads** (D14): needs the T1 decision on counters and the pool.
7. Elm's debug crash 4 text (`[object Object]` [A]) and the reachability of unused ports: one run each on `elm0193` in E3a's first
   step, before the tests are written.

---

## 10. Proposed entries for the shared files (not applied)

Decisions: a DONE entry for this note; one DECIDED entry for the answers below; the L21 note extended to `Word64` (`JUINT`); two
recorded deviations (crash 4's second line is `errorToString`; `Json.Value` flags refuse to start when absent). Checklist: E3 gets
sub items E3a to E3f; G30 gets "makes D10 zero copy".

## 11. Decisions for the user, in recommendation order

1. **D3** ownership: `send` consumes, callbacks borrow, `retain`/`release` (the basis of everything else).
2. **D1** the host value is the `Json.Value` tree behind `fic_hv`, plus vector and unsigned nodes; typed structs deferred to F1.
3. **D7** errors: the API returns codes and Elm's `errorToString` text (slow path on failure only); only the runner exits.
4. **D2** the function set and the generated `<module>_ports.h`.
5. **D6** payloads: Elm's set plus `Array`, `Vector`, sized integers, `Float32`; custom types and `Dict` stay refused.
6. **D5** numbers: range checks as decided; `Word64` via a `JUINT` node (extends L21); `Float32` rounds.
7. **D11** flags: `fic_app_start(flags)`, `FIC_FLAGS`/`FIC_FLAGS_FILE` (and which wins), absent = `undefined`, crash 2 text.
8. **D4** strings: UTF-8, one validated copy in, zero copy out, `string_alloc`/`seal` for large text.
9. **D9** raw vectors: the vector object crosses, zero copy out, `vector_alloc` in; no external buffers.
10. **D10** `Vector Word8` with staging buffers until G30 (rather than waiting for G30).
11. **D8** the text adapter over the value API; the runner rebuilt on it.
12. **D12** re-entrancy as Elm: a callback may send and (un)subscribe.
13. **D14** threads: loop thread only, plus `fic_post` and `fic_post_json`.
14. **D13** embedding loop functions and holds; **D15** teardown and after-stop behaviour.
15. **D16** the benchmark cases and thresholds; the slice plan of section 8 with Opus reviews after E3a+E3b and E3c+E3d.
