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
