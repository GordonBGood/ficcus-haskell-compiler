# Ficcus against safe Rust on the benchmark programs

Rust session, 14 Nov 2026. Branch `bench/rust` (from `ficcus` at 5721dae2). Files: `targets/rust/*.rs`, `ficcus-tools/rust_bench.py`, this note. Nothing else was touched.

Toolchain: rustc 1.100.0 (0ef1bc386 2026-11-09), cargo 1.100.0 (not used; plain `rustc --edition 2021`). Machine: AMD Ryzen 7 7840HS, gcc 16.2.1, idle (load below 1, 23 GB available). Ficcus = `bin/elmfic67 --rc`, gcc -O2 -ffp-contract=off, measured by `s7_bench.py` in the same run as the Rust numbers (hand C too). Rust: `-C opt-level=3` and `-C opt-level=2`, no `target-cpu`, no `panic=abort`, default allocator (glibc malloc), no threads, no SIMD, std only. Method: serial, median of 5 wall times, `ulimit -v` 6 GB, one run of the program per measurement (Ficcus and Rust include process start; the hand C figure is the S7 per-run figure of a repeated run). Every Rust build (all variants, O2 and O3) printed exactly the golden output (checked by byte comparison before timing).

## Table

| program | Ficcus ms | hand C ms | Rust safe O3 | Rust safe O2 | Rust UNCHECKED O3 | O3/C | O2/C | O3/Ficcus | O2/Ficcus | UNCH/C | UNCH/Ficcus |
|---|---|---|---|---|---|---|---|---|---|---|---|
| sieve | 6.27* | 0.03 | 0.13 | 0.13 | 0.12 | (4.34) | (4.32) | (0.02) | (0.02) | (4.08) | (0.02) |
| fannkuch | 738.9 | 187.5 | 116.3 | 116.0 | 131.3 | 0.62 | 0.62 | 0.16 | 0.16 | 0.70 | 0.18 |
| spectral | 36.9 | 13.7 | 13.0 | 13.0 | 13.5 | 0.95 | 0.95 | 0.35 | 0.35 | 0.99 | 0.37 |
| nbody | 266.9 | 187.5 | 46.3 | 46.2 | 47.8 | 0.25 | 0.25 | 0.17 | 0.17 | 0.25 | 0.18 |
| mandel | 78.7 | 77.6 | 63.7 | 64.8 | - | 0.82 | 0.84 | 0.81 | 0.82 | - | - |
| bintree | 179.9 | 156.8 | 665.3 | 677.2 | - | 4.24 | 4.32 | 3.70 | 3.77 | - | - |
| wordfreq | 102.2 | 84.4 | 36.3 | 35.8 | - | 0.43 | 0.42 | 0.36 | 0.35 | - | - |

Ratios are Rust / other, so below 1 means Rust is faster. UNCHECKED = `get_unchecked`, an upper bound, never the comparison. Brackets and `*`: a time under 10 ms, dominated by start-up, ignore. Sieve: Rust and hand C are 1000 repeats divided by 1000; Ficcus is one run (6 ms is start-up); the hand C sieve is the hand-unrolled `primebench.c`, the Rust one the plain Elm algorithm, so that ratio is not a like for like.

Labelled variants (not the comparison):

| variant | O3 ms | O2 ms |
|---|---|---|
| bintree, Rc for the shared tree | 611.1 | 599.7 |
| wordfreq, HashMap (not equivalent to Dict) | 25.3 | 26.1 |

Extra measurement (not in `rust_bench.py`): hand C `bintree.c` and `wordfreq.c` built with `-DFIC_NO_POOL` (glibc malloc instead of the runtime's size-class pool), median of 5 wall times: bintree 518 ms (one run; the pooled build is 157 ms), wordfreq 94.0 ms per run (84.4 pooled).

## Choices that bear on the comparison (also at the top of each file)

- sieve: Vec<u8>, plain culling loop (not unrolled). fannkuch: Vec<usize>, permutations updated in place with a scratch copy per permutation; the Elm and Ficcus code copies persistent arrays. spectral: Vec<f64>, same operation order, A(i,j) recomputed. nbody: Vec of a Copy struct of 7 f64, updated in place. mandel: Copy structs, Vec<Vec<i64>>.
- bintree: `Option<Box<Node>>`; map over a unique tree is done in place by `&mut`, over a tree still in use by copying. A Box cannot express the *shared* tree of depth 20 (21 real nodes in Elm/Ficcus): the default build allocates all 2^21-1 nodes, flagged as a deviation; the Rc variant shares it as Elm does.
- wordfreq: BTreeMap<&str, i64> (B-tree, not red-black; words are slices of the lower-cased text, no per-word allocation); HashMap variant labelled.
- Float printing is JavaScript's (`js_float`, from Rust's shortest round-trip digits); `Math.round` is `js_round`.
- Not done: the Hamming and closure-stream programs (item 8), by the economy instruction.

## Where Rust is slower or faster

- **Faster than hand C** on fannkuch (0.62), nbody (0.25), wordfreq (0.43), mandel (0.82); equal on spectral (0.95). Safe Rust did these with in-place mutation of Vec and Copy structs (no reference counts, no copy of arrays), BTreeMap on borrowed slices. The hand C and Ficcus versions keep the Elm semantics of persistent Array and Dict.
- **Slower than hand C** only on bintree (4.2, Box, glibc malloc, 30 M allocations and frees). With the same allocator the hand C is 518 ms, so 1.28 of the 4.2 is the program and the rest the allocator. The Rc variant is 8 % faster than Box because it builds 21 nodes instead of 2 M for the shared tree.
- O2 and O3 differ by at most 3 % in every program.
- **UNCHECKED** is never faster than safe: fannkuch 131 against 116, nbody 47.8 against 46.3, spectral 13.5 against 13.0, sieve 0.12 against 0.13. No Rust program needed `unsafe` to match or beat hand C. Rc was needed only to reproduce the sharing of one part of bintree, and its time gain is 8 %.

## Ficcus against safe Rust O3 (Ficcus / Rust)

fannkuch 6.4, nbody 5.8, spectral 2.8, wordfreq 2.8, mandel 1.24; bintree 0.27 (Ficcus is 3.7 times faster than Rust there, with its pool allocator against glibc malloc).

What looks improvable in the Ficcus numbers (the causes are those already recorded in `docs/STAGE4-S7.md` part 2 section 3, not new findings): the largest gaps (fannkuch, nbody, spectral) are the programs the S7 profiles attribute to `Array.get`/`set` tree walks, the boxed record element of nbody and the closure calls of `foldl`/`initialize`; wordfreq is 2.8 against a Rust BTreeMap on borrowed slices and 1.2 against the hand C. mandel (1.24 to Rust, 1.01 to hand C) and bintree show nothing to gain against Rust. The comparison with hand C already shows where the compiler, not the algorithm, is behind: Rust confirms those programs can run 1.2 to 6 times faster than the current Ficcus output with the same algorithm, in safe code.

---

# Follow-up, part A (14 Nov 2026): better C baselines and scaled programs

(The sections above are the first report. Part B, the new Rust variants, and the merged final table follow when done.)

## A1. C baselines: gcc and clang, -O2 and -O3

Hand written C and the Ficcus generated C (the `--rc` output of `bin/elmfic67` already generated by `s7_bench.py`), each built with gcc 16.2.1 and clang 17.0.0 (swiftly toolchain) at -O2 and -O3; other flags as in `s7_bench.py` (`-std=c99 -ffp-contract=off -w`). Median of 5, ms per run (hand C by the S7 rule). **Best hand C** = the fastest of the four hand C builds. Rust figures from the same run (a second measurement of the first table, within about 3 %).

| program | hand gcc -O2 | hand gcc -O3 | hand clang -O2 | hand clang -O3 | best hand C | Ficcus gcc -O2 | Ficcus best build | Rust O3 | Rust O2 | O3/best C | O2/best C | Ficcus/best C | Rust O3/Ficcus |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| sieve | 0.03 | 0.03 | 0.03 | 0.03 | 0.03 (clang -O2) | 5.74 | 5.74 (gcc -O2) | 0.13 | 0.13 | (4.64) | (4.64) | (197.40) | (0.02) |
| fannkuch | 188.8 | 181.9 | 183.8 | 184.0 | 181.9 (gcc -O3) | 745.5 | 745.5 (gcc -O2) | 115.3 | 117.0 | 0.63 | 0.64 | 4.10 | 0.15 |
| spectral | 13.3 | 13.5 | 13.7 | 13.6 | 13.3 (gcc -O2) | 36.9 | 29.9 (gcc -O3) | 13.0 | 13.1 | 0.98 | 0.99 | 2.79 | 0.35 |
| nbody | 186.7 | 188.2 | 186.4 | 185.3 | 185.3 (clang -O3) | 269.3 | 257.9 (gcc -O3) | 46.0 | 47.9 | 0.25 | 0.26 | 1.45 | 0.17 |
| mandel | 78.4 | 78.2 | 73.0 | 72.8 | 72.8 (clang -O3) | 80.6 | 79.7 (gcc -O3) | 64.1 | 64.2 | 0.88 | 0.88 | 1.11 | 0.80 |
| bintree | 165.2 | 155.6 | 200.2 | 195.2 | 155.6 (gcc -O3) | 185.4 | 185.2 (gcc -O3) | 676.3 | 686.3 | 4.35 | 4.41 | 1.19 | 3.65 |
| wordfreq | 92.0 | 77.7 | 92.2 | 85.9 | 77.7 (gcc -O3) | 107.6 | 96.3 (clang -O2) | 35.6 | 36.0 | 0.46 | 0.46 | 1.38 | 0.33 |

The sieve row is start-up dominated for Ficcus (ignore its ratios; see A2). Ratios in the last three columns use the best hand C.

## A2. Scaled programs (`targets/scaled/`)

Copies of the Elm, C and Rust sources with larger parameters so that Ficcus runs at least 150 ms (existing targets untouched). Run: `python3 ficcus-tools/rust_bench.py --set scaled --out DIR`. Sizes: sieve 1 MB buffer (8,388,608 bits, primes up to 16,777,218, 1,077,871 of them; same odds-only bit packed algorithm and layout); sievestream limit 5,000,000 (348,513 primes), sievepq limit 6,000,000 (412,849). **Hamming cannot be scaled by n**: the numbers of the form 2^a 3^b 5^c below 2^63 are only about 13,000 and Elm's Ints are exact only to 2^53, so hamvec and hamheap are scaled by repetition: the count to (limit - k) is summed for k = 1..1000 (hamvec, 7,715,000 in total) and k = 1..300 (hamheap loop variant, 2,314,500), a different limit each time so that nothing is computed once. Hand C runs one pass (the existing hand C runs an extra untimed run). Outputs: the count and the limit printed by Ficcus, hand C (all builds' sources), Rust (sieve so far) and Elm under node agree on every program; Elm finished within 60 s on all of them (column shown).

| program | Ficcus ms (gcc -O2) | Ficcus best build | hand C best (build) | hand C unrolled best (build) | Rust safe O3 | Rust safe O2 | Rust UNCHECKED O3 | Elm node ms | Ficcus/best hand | Rust O3/best hand | Rust O3/Ficcus | answers agree |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| sieve | 323.0 | 312.6 (gcc -O2) | 76.3 (clang -O3) | 8.5 (clang -O2) | 12.9 | 13.2 | 12.9 | 4249 | 4.24 | 0.17 | 0.04 | yes |
| sievestream | 228.1 | 228.4 (gcc -O3) | 161.3 (gcc -O3) | - | - | - | - | 638 | 1.41 | - | - | yes |
| sievepq | 176.9 | 162.1 (clang -O2) | 139.3 (clang -O2) | - | - | - | - | 525 | 1.27 | - | - | yes |
| hamvec | 167.8 | 164.1 (gcc -O2) | 33.1 (gcc -O2) | - | - | - | - | 904 | 5.07 | - | - | yes |
| hamheap | 158.7 | 152.4 (gcc -O3) | 121.5 (clang -O3) | - | - | - | - | 555 | 1.31 | - | - | yes |

Hand C "plain" for the sieve is `sieve_plain.c` (the compiler-like emission with the runtime's vector); "unrolled" is the hand unrolled `primebench.c`, kept as an extra column. Rust sieve is the plain algorithm on a Vec<u8>. Ratios of the Rust programs of sievestream, sievepq and hamming follow in part B.
