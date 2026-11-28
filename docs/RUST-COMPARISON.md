# Ficus against safe Rust on the benchmark programs

Rust session, 14 Nov 2026. Branch `bench/rust` (from `ficcus` at 5721dae2). Files: `targets/rust/*.rs`, `ficus-tools/rust_bench.py`, this note. Nothing else was touched.

Toolchain: rustc 1.100.0 (0ef1bc386 2026-11-09), cargo 1.100.0 (not used; plain `rustc --edition 2021`). Machine: AMD Ryzen 7 7840HS, gcc 16.2.1, idle (load below 1, 23 GB available). Ficus = `bin/elmfic67 --rc`, gcc -O2 -ffp-contract=off, measured by `s7_bench.py` in the same run as the Rust numbers (hand C too). Rust: `-C opt-level=3` and `-C opt-level=2`, no `target-cpu`, no `panic=abort`, default allocator (glibc malloc), no threads, no SIMD, std only. Method: serial, median of 5 wall times, `ulimit -v` 6 GB, one run of the program per measurement (Ficus and Rust include process start; the hand C figure is the S7 per-run figure of a repeated run). Every Rust build (all variants, O2 and O3) printed exactly the golden output (checked by byte comparison before timing).

## Table

| program | Ficus ms | hand C ms | Rust safe O3 | Rust safe O2 | Rust UNCHECKED O3 | O3/C | O2/C | O3/Ficus | O2/Ficus | UNCH/C | UNCH/Ficus |
|---|---|---|---|---|---|---|---|---|---|---|---|
| sieve | 6.27* | 0.03 | 0.13 | 0.13 | 0.12 | (4.34) | (4.32) | (0.02) | (0.02) | (4.08) | (0.02) |
| fannkuch | 738.9 | 187.5 | 116.3 | 116.0 | 131.3 | 0.62 | 0.62 | 0.16 | 0.16 | 0.70 | 0.18 |
| spectral | 36.9 | 13.7 | 13.0 | 13.0 | 13.5 | 0.95 | 0.95 | 0.35 | 0.35 | 0.99 | 0.37 |
| nbody | 266.9 | 187.5 | 46.3 | 46.2 | 47.8 | 0.25 | 0.25 | 0.17 | 0.17 | 0.25 | 0.18 |
| mandel | 78.7 | 77.6 | 63.7 | 64.8 | - | 0.82 | 0.84 | 0.81 | 0.82 | - | - |
| bintree | 179.9 | 156.8 | 665.3 | 677.2 | - | 4.24 | 4.32 | 3.70 | 3.77 | - | - |
| wordfreq | 102.2 | 84.4 | 36.3 | 35.8 | - | 0.43 | 0.42 | 0.36 | 0.35 | - | - |

Ratios are Rust / other, so below 1 means Rust is faster. UNCHECKED = `get_unchecked`, an upper bound, never the comparison. Brackets and `*`: a time under 10 ms, dominated by start-up, ignore. Sieve: Rust and hand C are 1000 repeats divided by 1000; Ficus is one run (6 ms is start-up); the hand C sieve is the hand-unrolled `primebench.c`, the Rust one the plain Elm algorithm, so that ratio is not a like for like.

Labelled variants (not the comparison):

| variant | O3 ms | O2 ms |
|---|---|---|
| bintree, Rc for the shared tree | 611.1 | 599.7 |
| wordfreq, HashMap (not equivalent to Dict) | 25.3 | 26.1 |

Extra measurement (not in `rust_bench.py`): hand C `bintree.c` and `wordfreq.c` built with `-DFIC_NO_POOL` (glibc malloc instead of the runtime's size-class pool), median of 5 wall times: bintree 518 ms (one run; the pooled build is 157 ms), wordfreq 94.0 ms per run (84.4 pooled).

## Choices that bear on the comparison (also at the top of each file)

- sieve: Vec<u8>, plain culling loop (not unrolled). fannkuch: Vec<usize>, permutations updated in place with a scratch copy per permutation; the Elm and Ficus code copies persistent arrays. spectral: Vec<f64>, same operation order, A(i,j) recomputed. nbody: Vec of a Copy struct of 7 f64, updated in place. mandel: Copy structs, Vec<Vec<i64>>.
- bintree: `Option<Box<Node>>`; map over a unique tree is done in place by `&mut`, over a tree still in use by copying. A Box cannot express the *shared* tree of depth 20 (21 real nodes in Elm/Ficus): the default build allocates all 2^21-1 nodes, flagged as a deviation; the Rc variant shares it as Elm does.
- wordfreq: BTreeMap<&str, i64> (B-tree, not red-black; words are slices of the lower-cased text, no per-word allocation); HashMap variant labelled.
- Float printing is JavaScript's (`js_float`, from Rust's shortest round-trip digits); `Math.round` is `js_round`.
- Not done: the Hamming and closure-stream programs (item 8), by the economy instruction.

## Where Rust is slower or faster

- **Faster than hand C** on fannkuch (0.62), nbody (0.25), wordfreq (0.43), mandel (0.82); equal on spectral (0.95). Safe Rust did these with in-place mutation of Vec and Copy structs (no reference counts, no copy of arrays), BTreeMap on borrowed slices. The hand C and Ficus versions keep the Elm semantics of persistent Array and Dict.
- **Slower than hand C** only on bintree (4.2, Box, glibc malloc, 30 M allocations and frees). With the same allocator the hand C is 518 ms, so 1.28 of the 4.2 is the program and the rest the allocator. The Rc variant is 8 % faster than Box because it builds 21 nodes instead of 2 M for the shared tree.
- O2 and O3 differ by at most 3 % in every program.
- **UNCHECKED** is never faster than safe: fannkuch 131 against 116, nbody 47.8 against 46.3, spectral 13.5 against 13.0, sieve 0.12 against 0.13. No Rust program needed `unsafe` to match or beat hand C. Rc was needed only to reproduce the sharing of one part of bintree, and its time gain is 8 %.

## Ficus against safe Rust O3 (Ficus / Rust)

fannkuch 6.4, nbody 5.8, spectral 2.8, wordfreq 2.8, mandel 1.24; bintree 0.27 (Ficus is 3.7 times faster than Rust there, with its pool allocator against glibc malloc).

What looks improvable in the Ficus numbers (the causes are those already recorded in `docs/STAGE4-S7.md` part 2 section 3, not new findings): the largest gaps (fannkuch, nbody, spectral) are the programs the S7 profiles attribute to `Array.get`/`set` tree walks, the boxed record element of nbody and the closure calls of `foldl`/`initialize`; wordfreq is 2.8 against a Rust BTreeMap on borrowed slices and 1.2 against the hand C. mandel (1.24 to Rust, 1.01 to hand C) and bintree show nothing to gain against Rust. The comparison with hand C already shows where the compiler, not the algorithm, is behind: Rust confirms those programs can run 1.2 to 6 times faster than the current Ficus output with the same algorithm, in safe code.

> **The first report above is superseded by this follow-up** (same method; its numbers differ from the ones below by under 3 %, run to run). Ficus figures: `bin/elmfic67 --rc`, one `s7_bench.py` run (the same Ficus and hand C numbers feed every table of the base set).

# Follow-up (14 Nov 2026): better C baselines, scaled programs, more Rust variants

## 1. Base programs: all C builds, Rust, ratios to the best C

Hand written C and Ficus generated C each built with gcc 16.2.1 and clang 17.0.0 at -O2 and -O3 (other flags as in `s7_bench.py`: `-std=c99 -ffp-contract=off -w`); median of 5, ms per run. **Best hand C** is the fastest of the four hand C builds. Rust: `-C opt-level=3` and `2`, safe; every Rust output equals the golden file. Ficus / best C and Rust O3 / best C are the ratios to the best C; the last column is Rust O3 / Ficus (gcc -O2). The sieve row is start-up dominated for Ficus: ignore its ratios (see 2).

| program | hand gcc -O2 | hand gcc -O3 | hand clang -O2 | hand clang -O3 | best hand C | Ficus gcc -O2 | Ficus best build | Rust O3 | Rust O2 | O3/best C | O2/best C | Ficus/best C | Rust O3/Ficus |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| sieve | 0.03 | 0.03 | 0.03 | 0.03 | 0.03 (clang -O2) | 5.91 | 5.81 (gcc -O3) | 0.13 | 0.14 | (4.67) | (4.69) | (204.37) | (0.02) |
| fannkuch | 188.5 | 181.4 | 184.7 | 183.5 | 181.4 (gcc -O3) | 761.4 | 757.4 (gcc -O3) | 117.0 | 116.6 | 0.65 | 0.64 | 4.20 | 0.15 |
| spectral | 13.2 | 13.5 | 13.6 | 13.6 | 13.2 (gcc -O2) | 36.4 | 30.3 (gcc -O3) | 12.9 | 12.6 | 0.98 | 0.95 | 2.76 | 0.35 |
| nbody | 187.0 | 188.0 | 186.2 | 185.5 | 185.5 (clang -O3) | 269.6 | 258.0 (gcc -O3) | 47.2 | 48.5 | 0.25 | 0.26 | 1.45 | 0.18 |
| mandel | 78.4 | 78.1 | 74.1 | 72.6 | 72.6 (clang -O3) | 80.0 | 80.0 (gcc -O2) | 65.0 | 64.9 | 0.90 | 0.89 | 1.10 | 0.81 |
| bintree | 163.1 | 154.4 | 204.4 | 193.9 | 154.4 (gcc -O3) | 185.1 | 184.2 (gcc -O3) | 679.5 | 691.0 | 4.40 | 4.47 | 1.20 | 3.67 |
| wordfreq | 90.0 | 79.1 | 93.6 | 90.2 | 79.1 (gcc -O3) | 104.5 | 100.2 (clang -O3) | 36.2 | 37.4 | 0.46 | 0.47 | 1.32 | 0.35 |

Rust against Ficus and hand C (gcc -O2), with the UNCHECKED variant (`get_unchecked`, an upper bound, never the comparison):

| program | Ficus ms | hand C ms | Rust safe O3 | Rust safe O2 | Rust UNCHECKED O3 | O3/C | O2/C | O3/Ficus | O2/Ficus | UNCH/C | UNCH/Ficus |
|---|---|---|---|---|---|---|---|---|---|---|---|
| sieve | 6.27* | 0.03 | 0.13 | 0.14 | 0.12 | (4.43) | (4.45) | (0.02) | (0.02) | (4.09) | (0.02) |
| fannkuch | 738.9 | 187.5 | 117.0 | 116.6 | 133.9 | 0.62 | 0.62 | 0.16 | 0.16 | 0.71 | 0.18 |
| spectral | 36.9 | 13.7 | 12.9 | 12.6 | 12.9 | 0.94 | 0.92 | 0.35 | 0.34 | 0.94 | 0.35 |
| nbody | 266.9 | 187.5 | 47.2 | 48.5 | 48.5 | 0.25 | 0.26 | 0.18 | 0.18 | 0.26 | 0.18 |
| mandel | 78.7 | 77.6 | 65.0 | 64.9 | - | 0.84 | 0.84 | 0.83 | 0.82 | - | - |
| bintree | 179.9 | 156.8 | 679.5 | 691.0 | - | 4.33 | 4.41 | 3.78 | 3.84 | - | - |
| wordfreq | 102.2 | 84.4 | 36.2 | 37.4 | - | 0.43 | 0.44 | 0.35 | 0.37 | - | - |

Labelled variants (not the comparison): bintree `rc` = Rc for the shared depth-20 tree only; wordfreq `hashmap` = HashMap<&str, i64>, not equivalent to Dict; wordfreq `owned` = BTreeMap<String, usize> with owned Strings, like for like with Dict (the main wordfreq row uses borrowed slices):

| labelled variant | O3 ms | O2 ms |
|---|---|---|
| bintree rc | 624.5 | 618.0 |
| wordfreq hashmap | 25.8 | 26.3 |
| wordfreq owned | 42.9 | 45.5 |

Hand C builds: gcc -O3 is the best for fannkuch, bintree, wordfreq; clang -O3 for nbody, mandel; gcc -O2 for spectral; the differences are 0 to 15 % (wordfreq 90.0 to 79.1 ms, bintree 163.1 to 154.4 ms). The Ficus generated C gains from another build only in spectral (36.4 to 30.3 ms with gcc -O3, 17 %), wordfreq (104.5 to 100.2) and nbody (269.6 to 258.0); clang is slower than gcc on the Ficus bintree and sieve code.

## 2. Scaled programs (`targets/scaled/`)

Copies of the Elm, C and Rust sources with larger parameters, so that Ficus runs at least 150 ms (the existing targets are untouched). Run: `python3 ficus-tools/rust_bench.py --set scaled --out DIR`. Sizes: sieve 1 MB buffer (8,388,608 bits, primes to 16,777,218, 1,077,871 of them, same odds-only bit-packed algorithm and layout); sievestream limit 5,000,000 (348,513 primes); sievepq limit 6,000,000 (412,849). **Hamming cannot be scaled by n**: only about 13,000 numbers 2^a 3^b 5^c lie below 2^63, and Elm's Ints are exact only to 2^53; so hamvec and hamheap are scaled by repetition, summing the count to (limit - k) for k = 1..1000 (hamvec, 7,715,000) and k = 1..300 (hamheap loop variant, 2,314,500). **The count and limit printed by Ficus, hand C, Rust and Elm under node agree on every program** (Elm finished within 60 s on all; its column is shown).

| program | Ficus ms (gcc -O2) | Ficus best build | hand C best (build) | hand C unrolled best (build) | Rust safe O3 | Rust safe O2 | Rust UNCHECKED O3 | Elm node ms | Ficus/best hand | Rust O3/best hand | Rust O3/Ficus | answers agree |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| sieve | 353.1 | 325.3 (gcc -O2) | 43.1 (clang -O2) [was 80.4: two runs, see the correction] | 9.2 (clang -O3) | 13.5 | 12.2 | 12.5 | 4374 | 8.19 | 0.31 | 0.04 | yes |
| sievestream | 231.3 | 228.0 (gcc -O3) | 163.1 (gcc -O3) | - | 528.1 | 517.1 | - | 655 | 1.42 | 3.24 | 2.28 | yes |
| sievepq | 179.0 | 162.1 (clang -O3) | 139.9 (clang -O2) | - | 281.0 | 284.4 | - | 561 | 1.28 | 2.01 | 1.57 | yes |
| hamvec | 171.4 | 167.8 (gcc -O2) | 35.1 (gcc -O2) | - | 26.5 | 26.4 | - | 910 | 4.88 | 0.76 | 0.15 | yes |
| hamheap | 160.3 | 152.8 (gcc -O3) | 120.8 (clang -O3) | - | 212.4 | 215.6 | - | 558 | 1.33 | 1.76 | 1.32 | yes |

Labelled Rust variants of the scaled programs: sieve UNCHECKED 12.5 ms (above); sievepq BinaryHeap 199.2 ms (not equivalent: an array heap sifted in place, no persistence).

Rust versions and choices (header of each file): hamvec: Vec<i64> push, three cursors. hamheap: the Elm algorithm with a persistent Box heap in the consuming style (a node taken by value and rebuilt: one new Box per step, the old one freed), log representation as in Elm. sievepq: the same persistent Box heap; **deviation, flagged**: the base primes are read from a Vec of the primes found so far and the stream is consumed by a loop (the Elm code uses a second lazy self-referential stream); the heap work is the same. sievestream: the same structure as Elm, `Cis<T>` = struct with `Box<dyn FnOnce() -> Cis<T>>` (every thunk is used once per branch, so moves suffice, no Rc). Sieve: plain algorithm on Vec<u8>. Hand C "plain" for the sieve is `sieve_plain.c` (the runtime's vector with bounds and uniqueness test per access), "unrolled" the hand unrolled `primebench.c`, kept as an extra column.

## 3. What changed in the picture

Ficus (gcc -O2) against safe Rust (O3), same algorithm, Rust over Ficus time ratio inverted: Ficus / Rust.

| scenario | Ficus ms | Rust safe O3 ms | Ficus / Rust | Ficus / best hand C |
|---|---|---|---|---|
| sieve, 1 MB buffer (Vector-like) | 353.1 | 13.5 | **26** | 8.2 (hand C plain 43.1, one run; unrolled 9.2) |
| hamvec, 1000 repetitions (Vector-like) | 171.4 | 26.5 | **6.5** | 4.9 |
| fannkuch (Vector-like) | 738.9 | 117.0 | **6.3** | 4.1 |
| nbody (Vector-like, record elements) | 266.9 | 47.2 | **5.7** | 1.45 |
| spectral (Vector-like) | 36.9 | 12.9 | **2.9** (2.3 with the gcc -O3 build) | 2.8 |
| mandel | 78.7 | 65.0 | 1.2 | 1.10 |
| wordfreq (Dict) | 102.2 | 36.2 borrowed, 42.9 owned | 2.8 / 2.4 | 1.3 |
| hamheap (persistent heap) | 160.3 | 212.4 | **0.75** | 1.33 |
| sievepq (persistent heap + stream) | 179.0 | 281.0 (BinaryHeap 199.2) | **0.64** (0.90) | 1.28 |
| sievestream (closures) | 231.3 | 528.1 | **0.44** | 1.42 |
| bintree (allocation), Box | 179.9 | 679.5 (Rc 624.5) | **0.26** | 1.20 |
| bintree, ARENA (nodes in a Vec, indices) | 179.9 | 144.5 (BUMP 146.2) | **1.25** | 1.17 (hand C 154.4) |

- **The gap to Rust is a Vector gap.** Wherever the algorithm mutates a flat array in place (sieve, hamvec, fannkuch, nbody, spectral) safe Rust is 2.9 to 26 times faster than Ficus. Where the algorithm is persistent (heap, stream of closures, allocation of trees) Rust written in the same style is *slower* than Ficus, by 1.3 to 3.8 times, and still 1.1 times slower with an in-place BinaryHeap in sievepq; the Ficus compiler is within 1.2 to 1.4 of the best hand C there. The first report, whose sieve was start-up dominated and whose hand C unrolled sieve could not be compared, did not show this.
- **The sieve is the largest gap (26) and the clearest.** Ficus (Array) is 8.2 times the *hand C plain* sieve, which uses the old runtime vector, and the hand C plain is itself 3.2 times Rust (a runtime call with bounds and uniqueness tests per byte against a checked index that the optimizer reduces to a loop; the call copies the byte with a `memcpy` of a run-time size, see the correction). hamvec has the same shape (4.9 against hand C, 6.5 against Rust).
- **The compiler choice for C (gcc or clang, -O2 or -O3) moves hand C by at most 15 % and the Ficus C by at most 17 %**, and nothing reorders; allocation-heavy bintree is best with gcc -O3, and Ficus beats Rust there because Rust used glibc malloc (hand C with glibc malloc: 518 ms; with the runtime pool 154).
- **UNCHECKED still gains nothing** (sieve 13.5 to 12.5 ms, spectral equal, fannkuch and nbody slower): no bounds check is the bottleneck in safe Rust.

What looks improvable in the Ficus numbers (from the data above, not new analysis): (1) the `Array` of Ints, Floats and flat records as an unboxed, in-place Vector, which is what the five Vector-like rows measure (the S7 profiles, already recorded, put the cost in `Array.get`/`set` walks and per-update uniqueness checks, the boxed nbody elements and `foldl` closures); (2) code emitted around the vector calls, shown by the sieve: Ficus 353 ms against 80 ms for the hand C using the same runtime; (3) wordfreq, 2.4 to 2.8 times Rust with a BTreeMap and 1.3 times the hand C. Nothing in the persistent-structure rows (heaps, streams, trees) is behind Rust.

## 4. bintree: arena and bump variants, and how much of the gap is the allocator

`targets/rust/bintree_arena.rs` (safe, std only, default global allocator; output equals the golden file; same measurement as above, `--only bintree,bintree_arena`): nodes are `Node { l: u32, i: i64, r: u32 }` in a `Vec`, links are indices. **ARENA** (default build): one Vec per tree with the exact capacity, freed by dropping it (one malloc and one free per tree, not per node). **BUMP** (`--cfg bump`, hand written, 5 lines): one scratch Vec reused for every short-lived tree, `clear()` resets the allocation pointer, so after the first tree the allocator is never called; the long-lived, shared (both links the same index, 21 nodes) and map-test trees are ordinary arenas. Map over a unique tree is in place on the arena, over a tree in use a copy into a new arena.

| bintree | O3 ms | O2 ms | O3 / Ficus (179.9) | O3 / hand C pool (154.4 to 156.8) |
|---|---|---|---|---|
| Box (one malloc/free per node) | 684.1 | 682.9 | 3.80 | 4.36 |
| Box + Rc for the shared tree | 613.0 | 613.1 | 3.41 | 3.91 |
| ARENA | 144.5 | 145.0 | **0.80** | 0.92 |
| BUMP | 146.2 | 148.4 | 0.81 | 0.93 |

**How much of the gap is the allocator.** Of the 504 ms by which the Box program is slower than Ficus (684 against 180), the arena removes 540 ms (79 % of the Box time): with the per-node malloc/free gone, safe Rust takes 144.5 ms, 0.80 of Ficus and 0.92 of the best hand C. So essentially the whole gap is the per-node allocation (glibc malloc and free, plus the loss of locality that comes with it) and none of it is the language or the optimizer; Ficus and the hand C avoid it with the runtime's size-class pool (hand C with plain glibc malloc: 518 ms, with the pool 154 ms). The BUMP variant, which calls the allocator not at all for the short-lived trees, is no faster than ARENA (146 against 144.5 ms): one malloc per tree is already negligible, so what remains in the 145 ms is the work itself. The Rc variant helps only by 11 % (it shares the depth-20 tree, 21 nodes instead of 2 M); an arena shares it in the same way, so ARENA includes that saving too.

## Correction (V3, 16 Nov 2026): the hand C plain sieve figure

`sieve_plain.c` does the work once for the answer and then `NUMLOOPS` (default 1) more times, so the "80.4 ms" of the scaled table (hand C plain, clang -O3) was **two runs**. One run (`-DNUMLOOPS=0`, the same work as the Ficus and Rust programs), median of 5, whole process: gcc -O2 46.2, gcc -O3 46.3, clang -O2 43.1, clang -O3 45.2 ms; best 43.1 (clang -O2). The table rows above are corrected accordingly (Ficus Array / hand C plain 8.2, Rust / hand C plain 0.31; the other columns of the sieve row were not changed). Why the plain hand C is slower than the Ficus Vector sieve (29.6 ms in V1): docs/STAGE4-V3.md section 1 (the runtime's `fic_vec_set` and `fic_vec_repeat` copy each element with a `memcpy` of a run-time element size: a library call per culled byte).
