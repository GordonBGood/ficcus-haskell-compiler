# A5a review cases (docs/A5A-REVIEW.md)

    python3 ficcus-tests/a5ar/gen.py                     # (re)writes cases/ (every case comes from gen.py)
    TMPDIR=/home/gordon/claude-tmp python3 ficcus-tests/a5ar/run.py [--elm ../bin/elmficA5a] [--only a,b] [--js] [-v]

Run from the worktree root. Each case is compiled to C with `--no-rc` (gcc -O2) and `--rc` (ASan+UBSan, FIC_STATS,
FIC_NO_POOL, 0 live required). The expected output is `twin/` (plain Elm, run by bin/elm0193 + node) or `expected.out`.
`--js` also compiles to JavaScript (D6) and prints the result.

Expected on elmficA5a (2026-11-26):

| result | cases |
|---|---|
| ok (no-rc and rc) | everything not listed below |
| **OUTPUT DIFFERS** (finding M1) | builtin-decides-append (`("{}","{}",2)`, Elm `("\"ab\"","[1,2]",6)`) |
| **CC-FAIL** (finding M1) | builtin-decides-inferred (C returns `int` as `fic_ref`) |
| **FICCUS cannot specialize** (finding M2) | share-recursive-ambiguous, share-recursive-top |
| **FICCUS cannot specialize** (finding B2) | spec-deep-inferred-9, spec-deep-inferred-12 |
| **MEMBER TYPE MISMATCH** (finding B1; A3b runs them) | order-rule1-let, order-rule1-let-after, order-rule1-let-swapped |
| rejected, correct | share-outer-reject (TYPE MISMATCH), hold-structure-reject (TYPE MISMATCH), hold-eta-value (TYPE MISMATCH, MR by D4), share-nonrec-ambiguous (UNKNOWN MEMBER TYPE), subj-undetermined-let (MISSING CONSTRAINT, old text) |
| pre-existing (A3b too) | builtin-decides-float32 (FICCUS "the type of `a` is not known here") |

With `--js`: d6-import-only, d6-unused-local, d6-mutual, dev2-* refused (CONSTRAINED FUNCTIONS, D6); d6-let-js and
elm-let-numbers run and equal elm0193.
