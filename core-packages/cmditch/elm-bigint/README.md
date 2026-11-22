# cmditch/elm-bigint, Ficcus core package

The Ficcus implementation of the API of `cmditch/elm-bigint` **2.1.2** (`BigInt.fic`: limb vector, Karatsuba, Knuth D; design,
tests and benchmarks in `docs/BIGINT.md`). It exposes the same 25 names with the same types and the documented behaviour.

## Where it is used

In a build to C (`--output=x.c`, `x.mono`) of a project whose `elm.json` depends on `cmditch/elm-bigint` at a version in
**`2.0.0 <= v < 3.0.0`** (table: `builder/src/Ficcus/CorePackages.hs`), this package is compiled in place of the Elm package
(`Elm.Details.build`; the compiler prints `Ficcus: cmditch/elm-bigint 2.1.2 is replaced by the core package`). The project still lists the
Elm package's own dependencies (`elm-community/list-extra`, `maybe-extra`, `rtfeldman/elm-hex`) because the solver needs them; this
package does not use them. Its only imports are `Vector` and `Bitwise64` (overlay modules of the C build) and elm/core.

Not substituted: JavaScript builds (always the Elm package), a version outside the range, and a project with
`"ficcus-core-packages": false` at the top level of its `elm.json` (the official 0.19.3 compiler ignores the field).

## Differences from 2.1.2 (crashes and real bugs only)

| case | Elm 2.1.2 | this package |
|---|---|---|
| `fromInt n` with `abs n >= 2^53` | wrong result at 2^53-1 and beyond (JavaScript numbers; limbs are built with `Float` arithmetic) | exact over the whole 64 bit `Int` range |

Everything else (also `div x 0 = 0`, `modBy` with the sign of the numerator, `gcd 0 (-5) = -5`, `pow 1 (-1) = 0`, `0^0 = 1`,
`Debug.toString` printing the representation) is kept as in 2.1.2. No crash of 2.1.2 was found by the differential tests (about 12,000
cases per seed). A program whose output depends on the first row differs between its C and JavaScript builds, which is the
documented price of fixing it; the differential programs of `ficcus-tests/bigint` stay below 2^52 for `fromInt`.

Limbs are `Int` (31 bits) until `Word32` exists.
