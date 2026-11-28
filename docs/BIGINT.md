# BigInt in Ficus (BIGINT session, branch `feat/bigint`)

A Ficus implementation of the API of `cmditch/elm-bigint` **2.1.2** (the version in `corpus/pkgs`), on `Vector Int`.
No compiler change; binary used: `bin/elmficA14` (head `f6385a05` of `ficcus`). Sonnet 5.5 commits.

## 1. Files

| path | what |
|---|---|
| `ficus-tests/bigint/src/BigInt.fic` | the package module (1434 lines), exposes exactly the 25 names of the Elm package |
| `ficus-tests/bigint/bigint_cases.py` | Python case generator (expected values from Python integers) |
| `ficus-tests/bigint/t/main_template.fic` | one test `Main`, valid Ficus **and** Elm (`BigInt` API only) |
| `ficus-tests/bigint/bigint_diff.py` | differential runner: modes `plain`, `dropall` (`FIC_DROP_ALL=1`), `san` (counted + ASan/UBSan, no pool), `elm` (the Elm package under node, same cases) |
| `ficus-tests/bigint/bbuild.sh` | build a program that imports `BigInt` (`BB_SRC` = other package source, used by the sweep) |
| `ficus-tests/bigint/bench/` | `bench.py` (median of 5), `bench_check.py` (benchmarks in the three modes), `kara_sweep.py`, `ham_bench.py`, `ref.c` (hand C), `gmpb.c` (GMP), `body/*.fic`, `ham/*.fic` |
| `ficus-tests/bigint/results/` | `bench.json`, `ham.json` (this report's numbers) |

Use: an application whose `source-directories` contain `ficus-tests/bigint/src` and `import BigInt`. Only this use is tested (see open question 1).

## 2. Design

* `type BigInt = Pos (Vector Int) | Neg (Vector Int) | Zer`; magnitude = limbs, least significant first, no zero limb at the top, zero is `Zer` only.
  One representation per value, so `==` on `BigInt` is right (tested: `canon` cases).
* Limb base 2^31, **`limbBits ()` is the one constant** (`base`, `mask` derive from it). Bound: `a*b + c + d` for four limbs < 2^63 needs `limbBits <= 31`.
  After sized integers: `Word32` limbs and `limbBits = 32` with `Word64` products; only the constants and the carry types change.
* The constants are functions of `()`: a top level value is a global variable in the C output, the C compiler cannot fold it, and `Bitwise64` shifts
  and masks by a variable made divmod 1.9x and toString 1.6x slower (measured: 0.94 s to 0.50 s, 0.27 s to 0.17 s). A static function that returns a literal is folded.
* Loops are tail recursive with the vector as an argument and result; a vector built by pushes (`withCapacity`) or by `Vector.repeat` is unique, so every
  `set`/`push` is in place. `FIC_WARN_COPY=1`: no copy warning, `vec_copy 0` in all 8 benchmarks (counters below).
  A copy happens only when a vector with several owners is changed on purpose: the first `divSmall` pass of `toString` on a `BigInt` that is still referenced copies its magnitude once.
* add/sub: schoolbook, output by pushes (no zero fill). Multiplication: a power of two operand is a shift (`pow2Exp`, one scan that stops at the first non zero limb);
  one limb operand: `mulLimb` (pushes); schoolbook with the shorter factor as the outer loop; unbalanced (`la >= 2 lb`) in pieces of `lb`; Karatsuba from **48** limbs.
* Division: power of two divisor = shift and `lowBits`; one limb divisor = one pass; else Knuth D (normalise by shift, `fixQ` correction, multiply-subtract with a signed
  carry `k = (p >> 31) - (t >> 31)`, add back).
* `toString`: repeated division by 10^9 in place, chunks consed (most significant first), `String.concat`. `fromIntString`: groups of 9 digits (`String.slice`, `String.toInt`), `v*10^k + g` in place.
  Hex: nibbles by bit position (31 bit limbs are not nibble aligned).
* `pow`: left to right square and multiply over the bits of the exponent (a `BigInt`: any size), so the multiply by the base is the cheap one (3^200000).
* Semantics of the Elm package that were kept, including its odd ones (checked against the package under node): `div` truncates towards zero and `div x 0 = 0`;
  `modBy den num` is the truncating remainder, sign of `num` (not of `den`), `Nothing` for 0; `divmod x 0 = Nothing`; `pow x 0 = 1` (also 0^0), negative exponent gives 0
  (also for base 1); `gcd 0 y = y` and `gcd x 0 = x` as they are (a negative argument stays negative); `fromIntString` accepts one leading `+` or `-`, rejects `""`, `"-"`, `"+"`,
  `"--1"`, spaces, non ASCII digits; `fromHexString` accepts `0x` (lower case x only) after an optional sign, upper or lower case digits, rejects `"0x"`, `"-0x"`, `"+0x5"`; `toHexString` is lower case without `0x`.

## 3. Tests (all pass)

`python3 ficus-tests/bigint/bigint_diff.py --modes plain,dropall,san,elm --n 400 --maxbits 500 --big 10 --seed S --work DIR`

* Cases: add, sub, mul, div, modBy, divmod, pow, gcd, compare/lt/gt/lte/gte, max, min, negate, abs, isEven, isOdd, toHexString, hex round trip, fromInt, fromIntString, fromHexString,
  structural equality of results (`canon`). Operands: all four sign combinations, 0, ±1, one limb, 2^31 ± d, (2^31)^k ± d, 2^j and 2^j ± 1, runs of ones and zeros,
  random of 1 to 500 bits; "big" operands of 800 to 20,000 bits (Karatsuba, chunked multiply, long Knuth division); denominators built from the quotient (exact, remainder 0, 1, d-1, d/2);
  **40 pairs found by a Python model of algorithm D that make the add back step run** (x4 signs); the error forms of the two parsers; powers with bases 0, ±1, ±2, 3, 10 and exponents around 31/32/62/63/64; `fromInt` over the 64 bit range including minInt and 2^63-1.
* Python expected values; the Elm package gets the same cases (`fromInt` limited to 2^52: the package gives a wrong result at 2^53-1, a JS Int limit).
* Seeds 3, 5, 6, 7, 8, 9, 11, 12, 13, 21 (each on the source of its time; the final source: seeds 9 and 21): 3,500 to 12,056 cases per mode and seed, **0 failures** in plain, drop-all, counted+ASan (leaks on); the Elm package passes the same cases at seeds 1, 2, 14, 21.
  The harness was checked to report a wrong expectation (a deliberately wrong line is listed as FAIL).
* `bench/bench_check.py`: the 8 benchmark programs (reduced sizes) in the three modes: all OK, `live 0`, no copy warning.
* Not done: a fuzz of random operation *sequences* (each case is one operation on fresh numbers), and an ASan run at the full benchmark sizes (counters show `live 0`).

## 4. Benchmarks

Serial, median of 5 (min and max in `results/bench.json`), whole process wall time (includes about 1 ms process start; for node about 40 ms), peak resident set from `/usr/bin/time`,
capped (4 GB address space, 200 s). `-O2`, gcc, `-ffp-contract=off`, counted (`--rc`) build without `-DFIC_STATS` for the time, a second run with `-DFIC_STATS` for the counters.
**The machine was not quiet:** load average 1.4 to 2.3 during the runs (other sessions, a browser); the repeats are within 5%, but absolute times may be a little high.
`libgmp` is installed (`/usr/lib64/libgmp.so`, `/usr/include/gmp.h`); the GMP column is `mpz` with the same operations. Output lines of all implementations equal Python's.

Full sizes (seconds, peak MB in brackets):

| benchmark | Ficus | hand C (same limbs, same algorithms) | ratio | GMP | Ficus / GMP |
|---|---|---|---|---|---|
| fact 10,000 (35,660 digits; includes toString) | 0.048 (2) | 0.037 (1) | 1.3 | 0.012 | 4 |
| fib 100,000 by addition (20,899 digits) | 0.160 (2) | 0.074 (1) | 2.2 | 0.017 | 9 |
| 3^200,000 (95,425 digits; includes toString) | 0.155 (3) | 0.155 (1) | 1.0 | 0.007 | 22 |
| build 3^209,589 (no printing) | 0.023 (2) | 0.013 (2) | 1.8 | 0.007 | 3 |
| toString of 100,000 digits (= tostr minus build) | 0.170 - 0.023 = 0.147 | 0.166 - 0.013 = 0.153 | 1.0 | 0.008 - 0.007 = 0.001 | 100+ |
| fromIntString of 100,000 digits | 0.073 (2) | 0.033 (1) | 2.2 | 0.007 | 10 |
| divmod: 10 x (100k digit / 50k digit) | 0.509 (2) | 0.305 (2) | 1.7 | 0.013 | 39 |
| mulbig: 5 x (232k bit * 252k bit), mod 10^9+7 | 0.116 (2) | 0.038 (2) | 3.1 | 0.007 | 17 |

Ficus counters (`FIC_STATS`, full sizes): `live 0` everywhere; `vec_copy 0`; `inplace` = 25.6M (fact), 114.6M (fib), 61.9M (pow3), 8.3M (build), 67.9M (tostr), 59.5M (fromstr), 313.7M (divmod), 62.9M (mulbig);
`allocs` 63.9k, 212k, 81k, 17k, 84k, 22k, 56k, 208k; `peak` live objects 11.9k, 7.0k, 36.4k, 40, 38.4k, 6, 16.7k, 50 (a limb vector is one object).

Elm package (`bin/elm0193`, node 21, dev build: Debug.log forbids `--optimize`) at sizes where it finishes, and Ficus at the same sizes (`ficus-s`):

| benchmark (size) | Elm + node | Ficus | Elm / Ficus | Elm peak MB | Ficus peak MB |
|---|---|---|---|---|---|
| fact 2,000 | 6.34 | 0.007 | 900 | 91 | 2 |
| fib 100,000 | 5.03 | 0.160 | 31 | 82 | 2 |
| 3^100,000 (47,713 digits), build only | 1.52 | 0.012 | 127 | 82 | 2 |
| 3^100,000 and its toString (tostr; node start is in both) | 1.52 | 0.048 | 32 | 82 | 2 |
| fromIntString 100,000 digits | 0.104 | 0.073 | 1.4 | 105 | 2 |
| divmod (1,000 digits / 500 digits) x 10 | 4.96 | 0.007 | 700 | 100 | 2 |
| mulbig (710 digit x 845 digit) x 5 | 1.67 | 0.007 | 240 | 83 | 2 |

(Elm's `toString` is free, its limbs are base 10^7; its `fromIntString` is linear for the same reason. Its `fib` is O(n) per addition like ours.)

hamnth (`bench/ham`, `results/ham.json`): the final decimal conversion of the digit vector multiply replaced by `BigInt.pow`, `mul`, `toString` (identical output):

| | old (small digit vector) | package |
|---|---|---|
| whole program, millionth (84 digits) | 0.023 | 0.023 |
| whole program, billionth (2^1334 3^335 5^404, 845 digits) | 7.227 | 7.444 |
| conversion alone, 20,000 x the millionth | 0.027 | 0.038 |
| conversion alone, 2,000 x the billionth | 0.053 | 0.058 |

The search dominates (the 3% in the whole program at 1e9 is within the noise of this machine); the package costs 1.9 us against 1.35 us per conversion of 84 digits, and is on par for 845 digits.
Resident set equal (204 MB, the queue).

Karatsuba threshold (`bench/kara_sweep.py`, median of 5, seconds; mulbig / pow3 3^200,000 / fact):

| limbs | 12 | 16 | 24 | 32 | 40 | 48 | 64 | 96 | 128 | never |
|---|---|---|---|---|---|---|---|---|---|---|
| mulbig | 0.171 | 0.155 | 0.131 | 0.129 | 0.126 | 0.124 | 0.124 | 0.125 | 0.135 | 0.599 |
| pow3 | 0.160 | 0.156 | 0.156 | 0.155 | 0.156 | 0.155 | 0.154 | 0.155 | 0.159 | 0.202 |
| fact | 0.083 | 0.084 | 0.080 | 0.083 | 0.084 | 0.079 | 0.084 | 0.084 | 0.084 | 0.083 |

Flat from 32 to 96; 48 chosen (the hand C uses 48 too). Karatsuba is 4.8x on mulbig and 1.3x on the squaring benchmark.
(The sweep ran before the push based loops; the curve is flat enough that it was not repeated.)

## 5. What is slow, and why

* **Ficus is 1.0 to 3.1x the hand C, 4 to 40x GMP** (and GMP is 10 to 100x anything portable: assembly inner loops, Toom, FFT, subquadratic division and conversion). The hand C is the right yardstick for the compiler.
* Per limb the generated loops do what the C does plus checks: `Vector.get` is a checked read (`fic_vector_checked` / `IN_RANGE`, 2 per add step, 3 per multiply-subtract step), the in-place `set` tests `rc == 1` and the range, `push` tests capacity;
  the hand C does neither. This explains fib (2.2x: 2 reads + a push per limb, one allocation per addition), divmod (1.7x: Knuth's inner loop), fromstr (2.2x) and mulbig (3.1x: Karatsuba is slice copies, `magAdd` temporaries and `addInto`, 208k allocations against a few thousand in C, each with a zero fill).
* `Vector.repeat` is an Elm level loop of pushes (no `memset`): the zero filled outputs (`schoolLoop`, `addInto`) pay for it; where the output is sequential I build by pushes instead (add 1.4x faster, fact 1.8x faster).
* A top level constant is a global variable in the C text (see section 2): the compiler should fold a top level `Int` with a literal body; the workaround in the package is the unit function.
* `toString` and `fromIntString` are quadratic (repeated division / multiplication by 10^9), like the hand C (equal: 0.166 and 0.170 s); GMP is subquadratic. A divide and conquer `toString` only helps with a subquadratic division (Burnikel-Ziegler or Newton):
  with Knuth D the top split costs as much as it saves, so it was **not done**.
* Memory is small and flat: 2 to 4 MB resident at 100,000 digits (a limb vector of 12k limbs is 96 KB); no leaks; node + Elm use 80 to 105 MB for the same.

## 6. Open design questions

1. **How is the package used?** Today: a source directory of the application. To replace `cmditch/elm-bigint` in a C build (a project that depends on the Elm package, whose `BigInt.elm` imports `elm-community/list-extra`) the compiler needs an overlay or override rule like the one for `Vector` and `Bitwise64` (`Build.crawlModule`: an overlay module yields to a project module of the same name; here the reverse is wanted for a package module). Not done: no compiler change allowed.
2. **API names.** The task text says `fromString`, `mod`, `eq`; the package 2.1.2 has `fromIntString`, `modBy`, and no `eq` (`==` works because values are canonical). I matched the package. Aliases (`fromString`, `eq`) or the later additions of the upstream package (`toInt`, `fromFloat`, ...) are one line each: decide.
3. **Bug compatibility.** Kept as in the package: `gcd 0 (-5) = -5`, `pow 1 (-1) = 0`, `0^0 = 1`. Elm's `fromInt` fails at 2^53-1 (JS limit): ours is exact over 64 bits. If these are to be fixed, a decision is needed (the differential test with the package would then need exceptions).
4. **Constants.** Keep the unit function workaround, or have the compiler fold literal top level `Int`s (then `limbBits`, `base`, `mask` can be plain values again). Measured effect 1.6 to 1.9x on the division and conversion loops.
5. **Vector API gaps** that would remove the remaining checks: an exposed `unsafeGet` (exists in `overlay/Vector.elm`, not exposed), a zero fill (`repeat` as a `memset`), a `fill`/`blit` for the Karatsuba assembly, and `slice` of a shared vector without a copy (a view). Each is a decision for the Vector owner.
6. **Sized integers.** With `Word32` limbs the check "limbBits <= 31" disappears; 2^32 limbs need `Word64` products and a carry that does not fit one product (use `mulhi` or 32x32 to 64 with a separate carry add). The limb vector would then be a flat 4 byte vector, half the memory.
7. **Subquadratic algorithms**, if big numbers matter: Burnikel-Ziegler division, then divide and conquer `toString`/`fromIntString`; Toom-3 above about 300 limbs; dedicated squaring (about 1.3x for `pow`).
8. **Hex limb alignment:** with 31 bit limbs hex goes through bit positions; a 32 bit limb makes it a byte copy.
9. Equality of two `BigInt` is `Vector` equality (elementwise); `compare` is the fast way; both are right because of the canonical form. `Debug.toString` of a `BigInt` prints the constructors and `Vector.fromList [...]`, not the number (the Elm package prints its internal lists too).
