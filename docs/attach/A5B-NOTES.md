# A5b: bare names of attached functions (selectors)

Branch `feat/a5b`, stacked on `feat/a5a` (a03a8f3b, not merged), 2026-11-26. Binary `bin/elmficA5b`. Design:
`docs/A5-INFERENCE-DESIGN.md` section 2 and D5 (approved). Out of scope: texts and titles (A5c; every message is the old
one), the solver (A5a).

## What changed

| where | what |
|---|---|
| `AST/Selectors.hs` (new) | The reserved home `elm/core:$attached`, the environment key `m$selector`, the selector scheme `$where t $inferred ($has$m a t)` and its reading (`parts`). |
| `Canonicalize/Selectors.hs` (new) | The candidate types (D5), the selector type of each member name (well known shape, or anti-unification), entered in the environment under `m$selector`. A module without candidates keeps its environment. |
| `Canonicalize/Module.hs` | `canonicalizeValues` calls `Selectors.register` after `Constraints.register`. |
| `Canonicalize/Expression.hs` | `findVarOrSelector` for an expression variable: Elm's lookup first; the selector only when the name is not in the environment. |
| `Ficcus/Mono/Marks.hs` | Every variable of a selector's type at a use is a root of the exact-key fixpoint. |
| `Ficcus/Mono/Spec.hs` | `resolve`: a selector is `memberRef` of its subject's exact type at the member type of the use (custom, built-in or sized). `deadByMembers`: a selector also decides the dead variables of a clone's body (`selectorDetermined`, through `Determined.fill`). |
| `Ficcus/Mono/Determined.hs` | exports `substitute`. |
| `Nitpick/Constraints.hs`, `Compile.hs`, `builder/Generate.hs` | `markSelectors`: a node `elm/core:$attached.m` (no code) per selector a module uses, so the object graph is complete; the JavaScript output refuses it under CONSTRAINED FUNCTIONS, "the attached function `add` by its bare name". |

No change in the solver: a selector is a `CForeign` with a `$where` scheme, so `Members.use` makes its requirement, as for a
call of a constrained function. The `$inferred` entry makes `Type.Dump` read it without hidden parameters.

### The rules as implemented

- **Lookup.** Locals (including `where` hidden parameters and siblings inside a `where` block), top level names, imports and
  default imports first, unchanged. Only a name that is not found becomes a selector, and only when the module has one of
  that name.
- **Candidates.** Local: the top level values `T$$m` of this module (the `where` members, and `derive` stubs, which are such
  values with signatures) that have a type annotation; the type is the annotation without the hidden parameters of the
  member's own `where` lines. Imported: the entries under every `T$` / `Prefix.T$` key of the qualified table (any import
  form, opaque types too), once per (home, type, member); the type is the real type of a `$where` scheme. The
  `pkg:Module.T$$m` members that travel in an interface are never in those tables, so they are not candidates.
- **Well known names** (`add`, `sub`, `mul`, `pow`, `div`, `idiv`, `mod`, `rem`, `append`, `compare`, `eq`, `neg`, `abs`,
  `fromInt`, `fromFloat`): the A3 shape, as soon as one candidate has the member. `compare` and `append` are Basics names,
  so they never reach the selector.
- **Anti-unification.** Candidates sorted by (home, type). In each candidate's type (aliases expanded) the occurrences of its
  own type with the arguments of its first occurrence become the subject `a`; variables are renamed apart. Where all agree
  the result keeps the structure; each tuple of disagreeing parts becomes one variable (the same tuple twice, the same
  variable; it keeps Elm's kind `number`, `comparable`, ... when every part has that kind). The name is not a selector when
  a disagreeing tuple contains the subject (`scale : Money -> Int -> Money` beside `scale : Float -> Vec -> Vec`), or when
  the subject is nowhere in the result (a member that does not mention its type).

## Cases

`ficcus-tests/attach/a5bgen.py --write` writes the cases and rows; `--expect` builds every twin (in `a5b-twins/`, on
`bin/elm0193` or `bin/elmficA5a`) and writes `expected.out`. Attach is now 307 cases (285 + 22).

### Converted (3)

| case | before (A5a) | A5b | twin |
|---|---|---|---|
| g71-q1-nosig-bare-member | NAMING ERROR x2 | RUN `Money 3` | oldc, `total` annotated |
| g71-q2-missing-all | NAMING ERROR | MISSING CONSTRAINT (`zero`, then `add`) | |
| g71-q2-missing-one | NAMING ERROR | MISSING CONSTRAINT (`a has zero : a`) | |

The two q2 rows keep the old title; A5c renames it to INCOMPLETE TYPE ANNOTATION.

### New (22)

| case | rule | result | twin |
|---|---|---|---|
| a5b-bare-inferred | D1 + selectors at two types | RUN `(Money 3,Vec 4 6)` | oldc |
| a5b-let-two-types | a let function using a selector at two types | RUN `(Money 4,Vec 2 4)` | oldc |
| a5b-value-typed | selector at a typed value and in typed expressions | RUN `(Money 0,Money 5,Vec 1 1)` | elm |
| a5b-default-literal | a top level value with a defaulted literal (`three = add 1 2`) | RUN `3` | elm |
| a5b-fromint | well known `fromInt` decided by an annotation | RUN `(Cash 500,Cash 600)` | oldc |
| a5b-mr-let-value | a let value at two types (MR) | TYPE MISMATCH | |
| a5b-subject-decides | anti-unified `f : a -> b` (B4 types), `get2 w = f (f w)` | RUN `(42,T 5,3)` | elm |
| a5b-parameterized | anti-unification with a type parameter (`Box x -> x`, `Tag -> String`) | RUN `(3,"t",[1])` | elm |
| a5b-shapes-differ | shapes that do not line up | NAMING ERROR `scale` | |
| a5b-poly-member | polymorphic member at two instances (rule 1) | MEMBER TYPE MISMATCH | |
| a5b-typo | member-name typo `ad` | NAMING ERROR `ad` (only; `zero` is now a selector) | |
| a5b-no-type-has-it | well known `mul` that no candidate has | NAMING ERROR | |
| a5b-not-named | members only in another interface (Lib passes on Lib2.Money) | NAMING ERROR | |
| a5b-elm-naming | an Elm program with an unbound `add` | NAMING ERROR | |
| a5b-import-exposing | `exposing (Money(..), Vec(..))` | RUN `(Money 1,Vec 1 2)` | oldc |
| a5b-import-qualified | `import Lib` only | RUN `Money 1` | oldc |
| a5b-import-opaque | opaque `exposing (Money)` | RUN `Money 1` | oldc |
| a5b-cross-module | an inferred function with selectors used from another module | RUN `(Money 3,Vec 4 6)` | oldc |
| a5b-sized | a sized type is a candidate (`add` at Float32) | RUN `"3.5"` (C only) | oldc |
| a5b-shadow-top | a top level `add` hides the selector | RUN `"ab"` | elm |
| a5b-shadow-local | a let-bound `zero` wins | RUN `Money 4` | oldc |
| a5b-js-refused | JavaScript refuses a selector | REJECT CONSTRAINED FUNCTIONS | |

**Elm programs unchanged.** a5b-elm-naming: the `--report=json` output is byte identical for `bin/elm0193`,
`bin/elmficA5a` and `bin/elmficA5b` (the terminal text differs between Elm and Ficcus already in A5a, not in A5b). The
gates (types matrix, elmdiff, typed corpus, JS identity, a3b-identity of the suite C text) check the rest.

A scratch probe (not a case): a selector inside a function whose `where` line renames the member (`a has add as plusA`)
meets the written requirement, and a selector in a let inside a constrained function too: `((Money 3,Vec 3 6),(Money 5,Money 10))`.

## Deviations from the note

1. **Expression position only.** The selector fallback is in the expression variable path, not in the record update target
   (`{ zero | x = 1 }` stays NAMING ERROR); a selector there could only be a type error.
2. **The subject is the type with the arguments of its first occurrence** (left to right). The note says "each owner type
   (with its parameters)"; with `T.map : (x -> y) -> T x -> T y` that would make `T x` and `T y` one variable. Occurrences
   with other arguments stay type applications and anti-unify as usual (`T y` beside `L y` becomes a variable the subject
   determines).
3. **"`a` survives" made precise**: no disagreeing tuple contains the subject, and the subject occurs in the result. So a
   member that does not mention its own type (`T.version : Int`) is not a selector.
4. **Marks**: every variable of a selector's type at a use is keyed exactly, not only the subject (the others are decided
   by the subject, so this adds no clones in the cases; it avoids computing the subject's index in Marks).
5. Candidates leave out a local member without a type annotation (an error of its own) and an imported entry that is
   already ambiguous under its key.

## Open points

- A5c: NAMING ERROR suggestions with the selectors in scope; the note's text for shapes that do not line up; the JS line
  "the attached function `add` by its bare name"; the MEMBER TYPE MISMATCH text ("this type annotation") for a selector's
  requirement (as for A5a's inferred ones).
- The anti-unified variables are named `b`, `c`, ... (`number1` for a kinded one); they appear in type errors.
- Derived members count as candidates locally (they are values before canonicalization) and when imported; the note does
  not say either way.
- An overlay or package module with a `where` block (the sized modules) now has selectors; this only changes programs that
  had a NAMING ERROR.

## Gates

2026-11-26, `BIN=elmficA5b KEEP=1 S=/home/gordon/claude-tmp/gates-a5b ficcus-tests/gates.sh` (log
/home/gordon/claude-tmp/gates-a5b.log), all green: runtime 0; attach 307/0 (with `--rc`, ASan+UBSan; rerun alone, see
below); sized-fuzz 40/0; stringdiff all agree; types 267 PASS + 1 XFAIL; JS identity 28/0; examples 298 x3; fbip 0;
effects-e2, e1review, effects-e1, e1p all ok; e1pr all ok (2 target rows); e1p-identity all ok; **a3b-identity against
elmficA5a: 100 compiles, 0 differ** (the C text of the 16 suite programs and the e1p/effects programs, `--rc` and
`--no-rc`); e2review gates all ok (3 info); rcfaults 2403/0 missed, rcfaults-big 239/0; rcgate-san ok; suite 16/16; typed
568 SAME + 12 BOTH_REJECT_SAME + 1 VERDICT_DIFF (salix-aws-spec, known); lib 108 PASS + 59 FIXED; elmdiff 1175 SAME, 0 DIFF.

The attach step of that run stopped in the harness: `cases/g71-q1-nosig-bare-member/expected.out` was missing.
`a5agen.py` imports `g71gen.py`, which runs its `main()` on import and, with `--write` on the command line, rewrites every
G71 case from `g71expect.py`; an `a5bgen.py --write` before the A5b block was in `g71expect.py` removed the file. It was
rebuilt from its twin (`r: Money 3`, the same as the A5b block, so a later `--write` writes the same) and attach was rerun
alone after the gates: 307 cases, 0 differ.
