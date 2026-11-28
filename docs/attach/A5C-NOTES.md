# A5f + A5c: the fixes of the A5a review, the texts of A5, the built-in `zero`

Branch `feat/a5c`, from `feat/a5b` 3609ab53 with `review/a5a` merged (37b1b1a9), 2026-11-26. Binary `bin/elmficA5c`. The
stack `feat/a5a`, `feat/a5b` is unmerged and stays so. Sources: `docs/A5-INFERENCE-DESIGN.md` (section 4, D7), `docs/A5A-REVIEW.md`,
`docs/attach/A5A-NOTES.md`, `docs/attach/A5B-NOTES.md`.

## Part 1: the review's findings

| finding | commit | fix | status |
|---|---|---|---|
| M1 (a built-in member decides a variable: wrong output or invalid C) | 195a35e0 | `Canonicalize.Constraints.checkShapes`: a `where` line of a signature with a well known name must have the well known shape at its variable (`WK.fitsVar`), as a type's `where` block must. `Spec.determinedByMembers` and `selectorDetermined` report a variable that only a missing member definition could decide instead of leaving it at `ref` (a guard: with the shape check no built-in member decides anything but its subject). | fixed |
| M1, builtin-decides-float32 (failed on A3b too) | 195a35e0 | its line `a has fromInt : Int -> z` is not the shape of `fromInt`, so it is now OPERATOR FUNCTION WITH THE WRONG TYPE; the program with the right shape runs (a5f-m1-float32-ok). Float32 has only well known members, so the old path cannot be reached any more. | fixed (by the shape rule) |
| M2 (a recursive group loses a requirement one name's type does not decide) | 5a2d211f | `Requirements.settle`: "by type" is the intersection of the closures of the names of the group. | fixed |
| B1 (rule 1 at every let boundary: acceptance depends on let names) | 6fc077df | `Requirements.improve` runs in `settle` on the obligations that go into a scheme and on the top level ones, no longer in `Solve.discharge`. | fixed |
| B4 (demotion not a fixpoint) | 6fc077df | `Requirements.demote` runs to a fixpoint (a few lines). No reproducer exists (the review could not reach it). The "every scheme obligation lands in a carrier" internal check was not added. | fixed, without a test |
| B2 (specializer fuel 8) | dc402af8 | `deadByMembers` and `determinedByMembers` iterate until nothing changes, with a guard of 10000 rounds that reports an error (the last round is no longer dropped). | fixed |
| B3 (the JavaScript refusal always suggests `Float -> Float`) | b28a1d41 | the D6 marker carries the type the solver would default the definition to (`h : Int -> Int`, `f : a -> ( Int, a )`, `half : Float -> Float`), or "give it one that names the types it is used at" when no default exists. | fixed |

The M1 fix also rejects the review's builtin-decides-written, -compare and -custom-only: each writes `compare : a -> a -> z`, which is
not the shape of `compare`. constraint-given-mismatch (`a has add : a -> Int -> a`) gets the shape error before the mismatch.

## Part 2: A5c

### Titles (D7)

`ficus-tests/attach/rename_titles.py` holds the table of section 4 and rewrites column 3 of `expected.tsv` and the quoted titles
in the generators (g71expect.py, g70gen.py, g71gen.py, a3bgen.py, a5agen.py, a5bgen.py, a5fgen.py); it then lists the rows whose
column 4 uses a retired word. `attach.py --print-reports` prints the first paragraph of each REJECT case. Every generator's
`--write`, run in a copy, reproduces the committed `expected.tsv` and cases.

### Texts

All in the voice of section 4 (first person, the code, the line to write, "attached function" and "has").

| report | what it says now |
|---|---|
| INCOMPLETE TYPE ANNOTATION | "This `plus` call needs `a` to have an attached `add` function:" (a bare name: "`zero` here is an attached function of `a`:"), then the annotation of the definition with its `where` lines and the new line, and "Or remove the type annotation: I can work out the `where` lines myself." A `let` definition: "a `let` definition cannot have a `where` block. Remove the type annotation". One type in sight and a bare name: "If you mean the one of `Money`, write `Money.zero`." A top level value under the monomorphism restriction: "`pl` is a value, not a function, so I give it one type ...", the annotation to write, or "make `pl` a function by giving it its arguments" (no more "I never infer constraints"). |
| AMBIGUOUS TYPE | "I cannot tell which type's `zero` to use here:" / "This `sum` call needs a type with attached `add` and `zero` functions, but I cannot tell which type:", then "Nothing around it settles the type. Add a type annotation that names it", with "for example: `empty : Money`" when the value's whole type is the subject, and the types in sight that have the functions. The literal case (L5): "Only a number literal gives the type, and `Int` and `Float` do not have one. Write a value of the type you mean instead of the literal, for example a `Money` value." A recursive group (M2): a note that the names call each other and which names' types settle the type and which do not. |
| NO ATTACHED FUNCTION | "This `sum` call needs `T` to have an attached `add` function, but `T` has only `zero` and `mul`." and "Add it to the `where` block of `T`:" with the line; for `/` (or any use needing `div`) at Int: "Use (//) for integers, or `toFloat` first."; the built-in note lists `fromFloat` and `zero`. |
| ATTACHED FUNCTION MISMATCH | a rule 1 conflict (two uses, one variable): "This `choose` call needs `a` to have an attached `pick` function with this type: ... But another use, on line 21, needs it with this type: ... A type has one attached function of each name, so `a` cannot have both." The variable is the real one, not the placeholder `a`. |
| OPERATOR FUNCTION WITH THE WRONG TYPE / WITHOUT TYPE ANNOTATION, ATTACHED FUNCTION WITHOUT TYPE ANNOTATION, UNUSED VARIABLE IN WHERE, WHERE ON A LOCAL DEFINITION ("Remove it: I work out the `where` lines of `let` definitions myself."), UNFINISHED WHERE, PROBLEM IN WHERE, NOT AVAILABLE IN JAVASCRIPT YET | reworded; the name-clash texts of `where` lines, the member lookup (`I cannot find an attached function `T.bar``), the syntax and derive texts too. |
| NAMING ERROR | the selectors in scope are suggestions (`ad` suggests `add`); a name that is an attached function of several types whose types do not line up adds "`scale` is an attached function of `Money` and of `Vec`, but with types that do not line up, so I cannot tell which one you mean. Write `Money.scale` or `Vec.scale`." |
| TYPE MISMATCH hints | L2 (MR): "`g` in `f` is a value, not a function, so I give it one type, and its use of `add` is settled by that type. Write what `g` stands for at each place, or make `g` a function by giving it arguments ..." (at a use of the let value, or at a call of the top level function that holds it, where the review saw the error). L6: after Elm's comparable hint, "Or keep `a` and say that it can be compared: add `where a has compare : a -> a -> Order` under the type annotation." only when a type with attached functions is in sight, so an Elm program keeps Elm's text. |

### The built-in `zero`

As decided: a member of `Int`, `Float` and the sized types, not in the `number` bundle, no `one`.

- `WK.builtinHas`: `zero` for Int and Float; a built-in shape `Value` (`s`) through `WK.builtinShapeOf`, so `zero` is still not a
  well known name (a custom type's `zero` keeps any type it likes, selectors anti-unify it as before).
- Spec: `RLit` (a member that is a literal), `zero` at Int is `0`, at Float `0` (the Float literal).
- Sized types: `gen_sized.py` writes `zero : T` / `zero = 0` beside `add` in Int8 ... Word64 and Float32 (Int64 and Float64 are
  Int and Float). The specializer clones that member (the literal at the type) instead of looking for a kernel.
- D3 defaulting and the B3 suggestion use the same table, so `sum [ 1, 2 ]` with `has zero` defaults to Int:
  constraint-no-members-at-all prints `3` (the erratum of the note is fixed in b100049f).

## Cases

`ficus-tests/attach/a5fgen.py` (15 a5f-* cases) and `a5cgen.py` (18 a5c-* cases, 1 converted row); twins in `a5f-twins/` and
`a5c-twins/` on `bin/elm0193` or `bin/elmficA3b`, never written by hand. Attach is now 340 cases (307 + 15 + 18). Both generators
import a5agen with an empty command line, so the g71gen import trap of A5B-NOTES cannot fire.

### A5f (from the review's reproducers)

| case | from | result |
|---|---|---|
| a5f-m1-builtin-append, -inferred, -written, -float32 | builtin-decides-* | OPERATOR FUNCTION WITH THE WRONG TYPE (C) |
| a5f-m1-append-ok | the well known shape, caller inferred | RUN `("\"ab\"","[1,2]",6)` (elm twin) |
| a5f-m1-float32-ok | the well known shape at Float32 | RUN `"3"` (oldc twin) |
| a5f-m2-recursive-ambiguous, -todo | share-recursive-ambiguous, share-recursive-top | AMBIGUOUS TYPE with the group note |
| a5f-b1-let, -let-after, -let-swapped, -let-renamed | order-rule1-* | RUN `((1,"s"),True)` (oldc twin: the same source on A3b) |
| a5f-b2-deep-9, -12, -30 | spec-deep-inferred-*, and 31 calls | RUN `43` (elm twin: one function per level) |

### A5c

| case | rule | result |
|---|---|---|
| a5c-zero-int | written sum at Int, and the empty list | RUN `(6,0)` (elm) |
| a5c-zero-float | at Float | RUN `(3.5,0.25)` (elm) |
| a5c-zero-sized | at Word8 and Float32 | RUN `(44,"0.75")` (oldc, `fromInt 0` written out) |
| a5c-zero-selector | `total xs = List.foldl add zero xs` (inferred) at Int, Float, Money | RUN `(6,1.5,Money 3)` (elm) |
| a5c-zero-own-wins | a type's own `zero` (Money 7) wins; Int beside it | RUN `(Money 10,4)` (oldc) |
| a5c-zero-neither | a type with `add` only | NO ATTACHED FUNCTION |
| constraint-no-members-at-all (converted) | `sum [ 1, 2 ]` | RUN `3` (elm) |
| a5c-js-idiv, a5c-js-let, a5c-js-neutral | B3 | NOT AVAILABLE IN JAVASCRIPT YET with `h : Int -> Int`, `f : a -> ( Int, a )`, the sentence |
| a5c-mr-hint | L2 hint | TYPE MISMATCH + the MR note |
| a5c-l6-hint | L6 hint | TYPE MISMATCH + the `where a has compare` line |
| a5c-incomplete-one-type, -show, -let | INCOMPLETE TYPE ANNOTATION forms | as above |
| a5c-ambiguous-value, -literal | AMBIGUOUS TYPE forms | `empty : Money`; the literal text |
| a5c-naming-shapes | shapes that do not line up | NAMING ERROR + the paragraph |
| a5c-naming-elm | an Elm program | Elm's NAMING ERROR |

Rows whose column 4 changed with the texts (by hand, from `--print-reports`): a3-err-div-others, a3-err-missing-member,
a3-f8-err-let-div-two-types, constraint-builtin, constraint-closed-type, constraint-let, constraint-record, constraint-twice,
dup-member, g70-private-type-flow, g71-q1-nosig-plus-money (the generators that own them were changed the same way).

## Elm programs

An Elm program has no candidate type, no `where` block and an empty member table, so: no selector, no `$owners` entry, no
obligation, no MR value, no L6 note, no D6 marker. Checked: a5b-elm-naming and a5c-naming-elm (NAMING ERROR) and
g71-elm-lt-plain-var (TYPE MISMATCH) give the same compiler output as elmficA5b; the gates' types matrix, JS identity, elmdiff
and the a3b-identity of the suite C text cover the rest (section Gates).

## Deviations

1. **M1's fix rejects the written D2 path with an off-shape well known name** (builtin-decides-written, -compare, -custom-only ran
   on A5a). The review proposed the shape check as fix 1, so this is intended, but it is a change for programs that A5a accepted.
2. **M2's ambiguity is AMBIGUOUS TYPE at the use** (with a note on the group), not INCOMPLETE TYPE ANNOTATION: annotating the
   name whose type has the variable would not help, since the other name's use still cannot settle it.
3. **Titles not in the D7 table keep their words**: MEMBERS ON A TYPE ALIAS, UNKNOWN DERIVED MEMBER, DERIVED MEMBERS (the JS
   refusal of `derive`). Their texts no longer say "member". Renaming them is the user's call (D7).
4. **The B3 suggestion is the type with every requirement's subject defaulted**, variables kept (`f : a -> ( Int, a )`); the
   variable names are those of the inferred scheme (`a`, not the source's `c`).
5. **INCOMPLETE TYPE ANNOTATION without the annotation**: when the generalization that finds the missing line has no annotated
   definition whose type mentions the variable (possibly some recursive groups, whose rigid variables Elm may generalize in a
   `let` without a header; not tested), the text says "Add this line to its `where` block" with the line only.
6. The selector hint ("write `Money.zero`") counts the custom types in the member table that have the member, not the
   candidate types of the canonicalizer (they differ only for types that travel inside another interface).

## Open points

- B4: no reproducer and no internal "every scheme obligation lands in a carrier" check (the review's second half).
- The L6 hint covers `comparable` only (not `appendable` or `number` on an annotated variable).
- The MR hint is matched by name at a call (`FuncName`); a mismatch reported elsewhere (deeper in an argument) has no hint.
- a5ar/README.md still describes the results on elmficA5a.

## Gates

2026-11-26, once at the end of part 2, `BIN=elmficA5c KEEP=1 S=/home/gordon/claude-tmp/gates-a5c ficus-tests/gates.sh` (log
/home/gordon/claude-tmp/gates-a5c.log), all green: runtime 0; attach 340/0 (with `--rc`, ASan+UBSan, 0 live); sized-fuzz 40/0;
stringdiff all agree; types 267 PASS + 1 XFAIL; JS identity 28/0; examples 298 x3; fbip 0; effects-e2, e1review, effects-e1, e1p
all ok; e1pr all ok (2 target rows); e1p-identity all ok; **a3b-identity against elmficA5b: 100 compiles, 0 differ** (the C text of
the 16 suite programs and the e1p/effects programs, `--rc` and `--no-rc`: programs without a `where` block are byte identical, no
C text difference to explain); e2review gates all ok (3 info, the recorded notes); rcfaults 2403/0 missed, rcfaults-big 239/0;
rcgate-san ok; suite 16/16; typed 568 SAME + 12 BOTH_REJECT_SAME + 1 VERDICT_DIFF (salix-aws-spec, known); lib 108 PASS + 59
FIXED; elmdiff 1175 SAME, 0 DIFF. Part 1 alone (before the texts): attach 322/0 with `--rc`, and the a5ar suite as in the table
of part 1.
