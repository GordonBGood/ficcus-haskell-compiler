# 4. Building, running, memory and speed

State: binary `elmficA16` (the workspace keeps the compiler builds as `bin/elmficNN`; a build of the fork is the `elm` executable).
Examples: `ficus-tests/guide/`. Timings in 4.5 were measured for this guide on 17 Nov 2026 with `elmficA14` (the same code paths; not repeated on A16) on an AMD Ryzen 7 7840HS,
gcc 16.2.1, a quiet machine (load below 1), median of 5 whole-process runs, serial, under `ulimit -v` 6 GB.

## 4.1 Build and run

The compiler writes one C99 file that contains the whole runtime. Any C compiler turns it into a program:

```sh
elm make src/Main.fic --output=main.c
gcc -std=c99 -O2 -ffp-contract=off main.c -o main -lm
./main
```

- The source can be `Main.fic` or `Main.elm`; the project has an `elm.json` as for Elm (dependencies `elm/core` and, for the
  five kernel libraries, the package that you import; their code is built in).
- Today a C program is a `Platform.worker` whose `init` prints with `Debug.log`; the lines go to **stdout** as `label: value`.
  There is no `Console` module yet (planned), and no `Html`, `Browser`, `Task`, `Time` (chapter 3).
- `--output=main.js` or `main.html` still gives Elm 0.19.3's JavaScript. `--optimize` and `--debug` are for that output.
- Compile time: about 1 s for a small program; the C file is about 900 KB because the runtime is in it; gcc -O2 compiles such a file in
  about a quarter of a second.
- **Use `-ffp-contract=off`.** Without it a C compiler may fuse `a * b + c` into one instruction (FMA) on some CPUs and a
  `Float` result then differs from Elm's in the last digit. Float printing equals JavaScript's `toString`.
- `-std=c99 -O2` is the tested setting. `-O3` and clang were measured and are no consistent gain (within 10 % either way,
  nbody under clang is 1.7 times slower). clang works; with sanitizers it needs `-fuse-ld=bfd`. `-lm` is needed; on a glibc older
  than 2.34 add `-lpthread` (the program runs `main` on a big-stack thread).
- Every example of this guide is built this way in three modes by `python3 ficus-tests/guide/run.py` (4.3).

## 4.2 What you can set

Compiler flags (`elm make`): `--output=x.c` selects the C back end; **`--rc`** (reference counting, the default, so the
flag changes nothing) and **`--no-rc`** (the oracle, 4.3).

Build options of the generated C (all optional; names are provisional and may be renamed, see `docs/FLAGS.md`):

| option | what it does |
|---|---|
| `-DFIC_STATS` | print one line of counters on stderr at exit (allocations, live and peak objects, in-place updates, copies, `vec_copy`; chapter 2); with counting, a nonzero exit status if objects are still live |
| `-DFIC_CHECK` | runtime checks: index of a vector read, count overflow |
| `-DFIC_NO_POOL` | plain `malloc`/`free` instead of the size-class pool; use it with valgrind and AddressSanitizer |
| `-DFIC_STACK_MB=n` | stack of the program thread in MB (default 1024; reserved address space, pages are used on demand) |
| `-DFIC_NO_BIG_STACK` | run `main` on the ordinary process stack; also what happens if the thread cannot be created, for example under a small `ulimit -v` |
| `-DFIC_JSON_MAX_DEPTH=n` | nesting limit of `elm/json` (default 1,000,000; 2000 without the big stack) |

Environment of the running program: `FIC_WARN_COPY=1` (the first copy of a shared vector prints a line, chapter 2).
Sanitizer build: `gcc -std=c99 -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=undefined -DFIC_NO_POOL -DFIC_STATS main.c -o main -lm`;
a leak, a use after free or an undefined operation stops the program with a report.

## 4.3 `--no-rc` as an oracle

`--no-rc` compiles the same program without reference counts: nothing is ever freed and every vector update copies.
The output must be byte-identical to the counted build, so it is the test of the counting: a counted program that prints
something else, crashes or leaves objects alive has a compiler bug, not a program bug. Use it on **small** programs only:
a `push` loop is quadratic and the memory grows without bound (a large benchmark with 450 million objects needs 22 GB).
Always cap it (`ulimit -v`). The runner of this guide builds every example three ways and compares:

| mode | compiler | C build | must |
|---|---|---|---|
| `norc` | `--no-rc` | `-O1` | print `expect.out` |
| `rc` | `--rc` | `-O1 -DFIC_STATS` | print `expect.out`, exit 0 (no live object at exit), and print the expected stderr lines |
| `san` | `--rc` | AddressSanitizer + UBSan, `-DFIC_NO_POOL` | the same, with no sanitizer report |

```sh
python3 ficus-tests/guide/run.py                       # all examples, three modes
python3 ficus-tests/guide/run.py --only d-int,v-fast   # some
python3 ficus-tests/guide/run.py --docs                # also check that every code block of docs/guide is a tested example
```

## 4.4 Memory

- **Reference counting.** Every heap value has an 8-byte header `{count, tag, pointer count, size class}`. A value is freed when its
  last holder goes away, at once, not at a later collection. A program ends with 0 live objects (`FIC_STATS` checks it). There is
  no cycle collector and no tracing; cycles cannot be built (as in Elm). Counts are not atomic: one thread runs the program.
- **What is heap and what is not.** Records and tuples are C structs with value semantics (no allocation for a record that
  stays in a function); inside a list cell, a custom type or a closure they are stored inline. Custom types, lists, strings,
  closures and vectors are heap objects. `Bool` and `Order` and constructors without fields are plain numbers or shared constants.
- **The pool.** Objects come from per-size free lists, so allocating and freeing is a few instructions. The hand-written C of the
  benchmarks with glibc `malloc` instead is 3 times slower on the allocation-heavy `bintree` (518 ms against 157 ms).
- **Arrays.** `Vector Int` is 8 bytes per element (`Vector Char` 4, `Bool` 1) plus a 40-byte header; a million `Int`s are 8 MB.
  The Elm `Array` costs more per element (boxed words in a tree). A byte buffer as `Vector Int` costs 8 bytes per byte (the P1 JSON benchmark peaks at
  640 MB for that reason; `Word8` vectors are planned).
- **Peak against hand C.** On the Hamming benchmark (10^8) the Ficus program uses 31 MB, hand-written C 26 MB, Rust 26 MB (4.5).
  Run with `-DFIC_STATS` to see the peak number of live objects of your own program.
- **Stack.** 1 GB reserved (not used) so that a non-tail recursion such as a hand-written fold over a long list works.
  If the thread cannot be created (for example under a `ulimit -v` below the stack size) the program silently runs on the ordinary
  process stack, typically 8 MB: build with `-DFIC_STACK_MB=64` for such a limit.

## 4.5 What is fast and what is not

Rule of thumb from the measurements: Ficus C is close to hand-written C for programs that build and take apart persistent
values (lists, trees, `Dict`, closures, heaps), and close to hand-written C and safe Rust for loops over a `Vector`.
It is slower where the Elm code uses `Array`, and where Rust or C can mutate a record in place.

**Vector programs, measured for this guide** (ms per run of the whole process; the work is done once by every version;
answers of all versions agree):

| program | `Array` version | `Vector` version | best hand C | safe Rust O3 | Array / Vector | Vector / hand C | Vector / Rust |
|---|---|---|---|---|---|---|---|
| nbody | 268.2 | **165.9** | 157.6 | 47.1 | 1.6 | 1.05 | 3.5 |
| fannkuch (10) | 736.9 | **214.9** | 153.8 | 118.5 | 3.4 | 1.40 | 1.8 |
| spectral | 38.5 | **13.8** | 12.5 | 13.9 | 2.8 | 1.10 | 0.99 |
| sieve (1 MB) | 322.6 | **29.0** | 24.8 plain, 9.0 unrolled | 13.9 | 11.1 | 1.17 (3.2 against unrolled) | 2.1 |
| hamvec (1000 reps) | 171.7 | **29.3** | 29.4 | 27.3 | 5.9 | 1.00 | 1.07 |

(`ficus-tools/v3_bench.py --elm bin/elmficA16 --runs 5`. Ficus: `--rc`, gcc -O2 -ffp-contract=off. Hand C: best of gcc and clang at -O2
and -O3. The sieve has one byte per flag in C and Rust and 8 bytes in a `Vector Int`.)

The `Vector` programs are 1.6 to 11 times faster than the `Array` programs (`docs/STAGE4-V3.md` measured 1.7 to 10.5 on a loaded
machine on 16 Nov) and within 1.0 to 1.4 of hand-written C except for the sieve against its unrolled version. Against safe Rust the
gap is 1.0 to 2.1, and 3.5 on nbody (records in a `Vector` are updated with boxed closure calls, where Rust mutates a `Copy` struct).
The older `Array` measurements (`docs/RUST-COMPARISON.md`, 14 Nov, `elmfic67`) put the `Array` versions 2.9 to 26 times behind Rust.
If speed matters in a C build, use `Vector`.

**Hamming numbers, the n-th (10^8)** (`targets/hamnth`, a three-pointer merge over a growing and trimmed `Vector`):

| 10^8 | Ficus `Vector` (gcc -O2) | best hand C (gcc -O2) | safe Rust O3 |
|---|---|---|---|
| time, ms | 629.5 | 511.7 | 631.7 |
| max resident memory, MB | 31.1 | 25.8 | 26.4 |
| Ficus / this | 1.00 | 1.23 | 1.00 |

(The 17 Nov run is the current one. `docs/STAGE4-V3.md` section 4 reports 3,293 ms and 62 MB for this program, 5.8 times hand C: that
was before `Vector.slice` of a unique vector was made in place, in FIX1; the proposal it made is done.)

**Persistent-structure programs** (`docs/RUST-COMPARISON.md` follow-up, 14 Nov, binary `elmfic67`, Ficus gcc -O2; time of
Ficus divided by the best hand-written C, and by safe Rust O3):

| program | style | Ficus / best hand C | Ficus / Rust |
|---|---|---|---|
| bintree | allocation of trees | 1.20 | 0.27 (Rust `Box` with glibc `malloc` is 3.7 times slower; with an arena Rust is 0.8) |
| mandel | records, `Float` loops | 1.10 | 1.24 |
| wordfreq | `Dict` of words | 1.32 | 2.8 (Rust `BTreeMap` on borrowed slices; 2.4 with owned strings) |
| hamheap | persistent heap | 1.33 | 0.75 |
| sievepq | heap and a stream of closures | 1.28 | 0.64 |
| sievestream | closures | 1.42 | 0.44 |

How to read it: within 1.1 to 1.4 of the best hand C everywhere except the flat-array loops, where `Array` is far behind and
`Vector` closes most of the gap. Rust beats the persistent programs only by changing the algorithm (arena instead of per-node
allocation, in-place `BinaryHeap`).

**What is slow, and what to do:**

1. **`Array` in a hot loop.** Use `Vector` (C builds only).
2. **A shared `Vector` updated in a loop.** Every update copies the whole vector: look at `vec_copy` in `FIC_STATS` (chapter 2).
3. **`Vector` of records with `String` or `List` fields** needs reference counts on every copy of an element; the remaining gap on nbody is mostly
   allocation of boxed records and closure calls of `foldl` (3.5 times Rust).
4. **Byte buffers as `Vector Int`**: 8 times the memory of a byte array.
5. **Indexing into long non-ASCII strings.** ASCII text is O(1); other text uses a scan or an offset cache (FIX2), so repeated random
   access into a very long non-ASCII string is slower than into ASCII.
6. **A regex with catastrophic backtracking** aborts at the step budget (chapter 3) instead of running for hours.
7. The `Vector` elision of the uniqueness test inside loops, the unboxed `Word8`/`Int32` elements and `Dict` allocation per level are
   known open items (`docs/COMPILER-HANDOFF.md`); no measurement above includes them.
