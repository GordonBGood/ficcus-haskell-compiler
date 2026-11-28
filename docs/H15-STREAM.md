# H15: start-up cost, and hamnth from a stream

Bench session, 17 Nov 2026. Branch `bench/p1` (no compiler change, `bin/elmfic80`, shared files untouched, nothing committed or merged). Machine: Ryzen 7 7840HS, gcc 16.2.1, clang 17, rustc 1.100.0, load below 1.5, serial, `ulimit -v` 6 GB.
Tools: `ficus-tools/startup_bench.py`, `ficus-tools/h15_bench.py`. Programs: `targets/hamnthstream/` (`src/HamNthStream.fic`, `src/HamNthStreamList.fic`, `hamnthstream.rs`; variant (a) and hand C are `targets/hamnth/`). Results: `results/h15/startup_bench.json`, `h15_bench.json`.

## 1. Start-up
Wall time of a process (fork, exec, exit included, same for all), 200 runs interleaved, median (minimum) ms; hamnth at 10^6 50 runs.
| program | bare C | hand C + ficrt.h | Rust | Ficus default | stack 8 MB | no big stack | no pool | no stack, no pool |
|---|---|---|---|---|---|---|---|---|
| trivial (prints 0) | 0.66 (0.30) | 0.72 (0.35) | 0.88 (0.45) | **0.86 (0.43)** | 0.88 | 0.74 (0.36) | 0.89 | 0.74 |
| hamnth n = 1 | | hand C 0.79 (0.38) | 0.95 (0.47) | **0.90 (0.45)** | 0.89 | 0.79 | 0.88 | 0.78 |
| hamnth n = 10^6 | | 6.76 (6.00) | 7.91 (7.08) | **15.5 (14.3)** | 15.1 | 16.0 | 15.5 | 16.1 |
- **Fixed start-up of Ficus: 0.86 ms against 0.72 ms for hand C (0.11 to 0.14 ms more), about the same as Rust (0.88).** Not large. Of the 0.14 ms, the 1 GB stack thread is about 0.12 ms (default 0.86, `FIC_NO_BIG_STACK` 0.74); a smaller stack (`-DFIC_STACK_MB=8`) costs the same as 1 GB (0.88): the price is the thread creation, not the size. The pool costs nothing measurable (`FIC_NO_POOL` 0.89, no change; slabs are malloc'd on first use).
- Subtracting the start-up from the 10^6 figures: Ficus 15.5 - 0.90 = **14.6 ms**, hand C 6.76 - 0.79 = **5.97 ms**, Rust 7.91 - 0.95 = 6.96 ms. The ratio Ficus / hand C goes from 2.3 to **2.4**: start-up is 0.1 ms of the 8.7 ms gap (1 %), **it is not the cause**. (FIX1 had 17.4 against 7.8 ms; today 15.5 against 6.8, the same ratio class, different session.)
- Where the rest comes from: the difference to hand C by size (40 runs, median): 10^5 2.9 ms, 3x10^5 5.0, 10^6 9.2, 3x10^6 12.2, 10^7 22.5, 10^8 106 (10^8 in the table below). Per element that is 7 ns (up to 10^6), 1.5 ns (10^6 to 10^7), 0.9 ns (10^7 to 10^8): the extra cost is paid in the **growth phase** of the queue (the first million elements), not per element at steady state. Probable cause, not tested: the doubling `Vector.push` allocates a new block and copies (`copied 61` in FIC_STATS), where hand C's `realloc` can grow a large block in place (mremap) with no copy and fewer page faults (RSS 8.0 MB against 3.9). A perf profile of the first 10^6 elements would settle it.

## 2. hamnthstream
`type CIS a = CIS a (() -> CIS a)`. The producer state `{ q : Vector Item, base, p2, p3, p5 }` is advanced by `step` (the body of the hamnth loop; `Item = { i, j, k, lg }`, `lg` the Float logarithm computed as in hamnth); the cell is `CIS x (\_ -> stream st2)`; the consumer `nth` skips n - 1 cells and the nth item is turned into digits by the hamnth code. (a) is the existing direct loop, (b) the stream with the Vector queue (in place: `vec_copy 0`, `inplace` as in (a)), (c) the stream with a list queue (one banker's queue per pointer, no Vector for the queue, 10^6 only). Rust `iter`: `Iterator::nth(n - 1)` on the struct; `dyn`: a `Box<dyn Iterator>` hidden by `black_box`, n calls of `next()` through the vtable. Hand C: the direct loop. Median of 5 (3 at 10^9), ms, peak RSS MB; every printed answer is equal (2^55 3^47 5^64 at 10^6).
| n | Ficus (a) direct | (b) stream | (c) list queue | **(b) / (a)** | hand C | Rust direct | Rust iter | Rust dyn | (b) / Rust iter |
|---|---|---|---|---|---|---|---|---|---|
| 10^6 | 17.5 (8.0 MB) | 48.8 (10.0) | 195.4 (5.8) | **2.8** (2.9 without start-up) | 8.4 (3.9) | 9.1 (4.1) | 10.8 (4.6) | 10.4 (4.9) | 4.5 |
| 10^8 | 617 (31) | 3,217 (41) | | **5.2** | 511 (26) | 652 (26) | 743 (34) | 731 (35) | 4.3 |
| 10^9 | 6,960 (204) | 32,651 (272) | | **4.7** | 5,822 (115) | 7,185 (115) | 7,974 (153) | 7,924 (153) | 4.1 |
(c) / (a) = 11.2, (c) / (b) = 4.0 at 10^6. Rust iter / direct = 1.19, 1.14, 1.11: the iterator costs 10 to 20 %, LLVM fused it into a loop of about the same speed; **dyn is as fast as iter (1.00)**: the indirect call per element is hidden by the 7 ns of work, and the Box version does not allocate per element.

FIC_STATS (whole run; the cell and the closure are the only per element allocations of (b)):
| | allocs | dups | drops | closures allocated | closure reuses (clo_steal) | Vector in place / copied |
|---|---|---|---|---|---|---|
| (a), 10^9 | 695 | 93 | 712 | 0 | 0 | 1.0 G / 78 |
| (b), 10^6 | 5.0 M | 1.0 M | 3.0 M | 1.0 M | 1.0 M | 1.0 M / 61 |
| (b), 10^8 | 500 M | 100 M | 300 M | 100 M | 100 M | 100 M / 74 |
| (b), 10^9 | 5,000 M | 1,000 M | 3,000 M | 1,000 M | 1,000 M | 1.0 G / 78 |
| (c), 10^6 | 23.0 M | 35.8 M | 29.9 M | 1.0 M | 1.0 M | 83 / 3 (list queue) |
Per element (b): **5 allocations, 1 dup, 3 drops, 1 closure** (the closure's memory is taken over by the next closure each step: `clo_steal` 1 per element); (a) has none. The other 3 allocations per element are heap objects for the `CIS` cell and the boxed tuple/record results (not itemised: the per tag count has closures, partial applications, strings and vectors only). The abstraction cost is (32,651 - 6,960) / 10^9 = **25.7 ns per element** (26.0 at 10^8): about 4 reference count operations (4 to 12 ns at 1 to 3 ns each, 16 to 47 %) and 5 pool allocations and frees (the rest). The queue still updates in place, so memory is not the problem: 272 MB against 204 MB at 10^9 (the extra is the larger Item, 32 bytes against 24). No fusion was implemented; the 4.7 to 5.2 times is what a fusion pass (or deforestation of the stream) would have to win back, against 1.11 to 1.19 for Rust's iterator.
