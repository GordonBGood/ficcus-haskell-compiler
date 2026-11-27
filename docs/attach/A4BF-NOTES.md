# A4bf: the A4b review's M1, M2, F1, F2, F3

Branch `feat/a4bf` (worktree `ficcus-haskell-compiler-a4bf`), from `feat/a4b` 639eeb26 with `review/a4b` bb79ea88 merged (the
report `docs/A4B-REVIEW.md` and the scratch cases `ficcus-tests/a4br/`). Binary `bin/elmficA4bf`. Not merged. Not in this session:
F4, F5, F6 and P1 (queued separately). None of them was entangled with these fixes (see section 4).

## 1. The fixes

| item | what the program does now | where |
|---|---|---|
| **M1 (b)** | `type A a = A a (B (List a))`, `type B a = B (A a)` with `derive compare` or `hash`: **CANNOT DERIVE** at once, naming the use (`B (List a)`), the type whose field holds it, and that the C generator does not support it | new `Canonicalize/DeriveChecks.hs` (`nonRegularGroup`), called from `Derive.checkParts`; reason `NonRegularGroup` in `Reporting/Error/Derive.hs` |
| **M1 (a)** | backstop in the specializer: more than 200 nested derived exact types stops `Spec.derivedAt` with "the derived `compare` of the type `A Int` reaches more than 200 nested types (...): a type in it is used at another argument inside itself (non-regular recursion), which the C generator does not support" | `Spec.derivedAt` (`sDerivedPath`), `Derived.derivedDepthLimit`, `Derived.nonRegularText` |
| **M2** | a field that is an extensible record (`T { r \| x : Int }`, also behind an alias or inside a container) is **CANNOT DERIVE** ("derived functions do not support an extensible record (`{ r \| ... }`), only a closed one") for `compare`, `hash` and the later structural members | `Derive.lacks` |
| **F1** | `a has compare` / `a has hash` at an open record is **NO ATTACHED FUNCTION**, with a paragraph that names the member(s) and says the type must be a closed record. A record whose row is still a flexible variable waits (it may close later). The same report replaces AMBIGUOUS TYPE when the row stays open to the generalization or to the end of the module (an unannotated function) | new `Type/OpenRecord.hs` (`recordRest`, `errorFor`); `Members.resolve`, `hold`/`sweep`/`leftovers`; `Reporting/Error/Type.hs` (`openRecordNote` instead of the built-in note) |
| **F2** | a written `hash` (or `compare`) of another type inside a derived one is **CANNOT DERIVE** showing the written type and the type needed, instead of the C generator's "another shape than the constraint" | `DeriveChecks.writtenShape` (`WK.fits` on the unwrapped, dealiased annotation), reason `WrongShape` |
| **F3** | `derive compare` or `derive hash` on a type whose `where` block writes `eq` is **CANNOT DERIVE**, pointing at the derive line and the written `eq` ("a derived `compare` ... ignores `Ci.eq`, so two values that are equal by your `eq` could compare as unequal, and a `Dict`, a `Set` or a sort would go wrong. Write `Ci.compare` yourself ...") | `DeriveChecks.besideEq`, error `BesideEq`; checked in `prepare` |

### M1 (b): the group walk

From the type at its own parameters, follow the constructor fields with the arguments put in, into every union of the module that
is in the type's group (it refers to the type and the type refers to it, transitively). The first time a union of the group is
reached, its arguments are recorded. Then a use of the type itself at other arguments than its parameters, or of another union
of the group at other arguments than its first use, is refused. This is as conservative as A4a's own check (`type T a = T (T Int)`
is refused though finite): `type A a = A (B Int) (B a)` with `B` referring back to `A` is refused too. The walk follows all unions
of the group, whatever their members: a type of the group with a written member is followed as well. A group cannot cross modules
(no import cycles), so the module's unions are enough.

### M1 (a): why 200, not 2,000

The review asked for A3's bound. A3's 2,000 counts distinct types in one walk. Here the depth is the nesting of derived exact types,
and each new one starts an A3 walk over a type one level deeper (`List (List ... Int)`), so the work is cubic in the depth. With
2,000 the review's program took 145 s per compile before the report (measured with the group check switched off in a scratch build);
with 200 it takes under a second. A regular program does not nest 200 derived types in one another. **This is a deviation from the
request.** The backstop cannot be reached from a source program while (b) is in place (a growing group always lies in one module,
and (b) refuses it), so it has no attach case. It was tested with a scratch build whose `nonRegularGroup` returned Nothing
(`/home/gordon/claude-tmp/elmficA4bf-nogroup`): `nonregular-mutual` and `nonregular-mutual-hash` are refused in about a second each.

## 2. Cases

`ficcus-tests/attach/a4bfgen.py` (standalone, like `a4bgen.py`, whose helpers it copies; it does not read `g71expect.py`, and
`g71expect.py` has no row these fixes change). 15 cases; attach is now 378. The two RUN cases have Elm twins on `bin/elm0193`
(`a4bf-twins/`), never hand-written outputs.

| case | what | result |
|---|---|---|
| a4bf-err-nonregular-mutual | the review's M1 reproducer (`compare`) | CANNOT DERIVE "refer to each other" (elmficA4bb did not stop) |
| a4bf-err-nonregular-mutual-hash | the same with `hash` | CANNOT DERIVE |
| a4bf-err-nonregular-three | a group of three, the growth in the third (`B a = B (C (Maybe a))`) | CANNOT DERIVE "A (Maybe a)" |
| a4bf-mutual-regular | a regular group: `Expr`/`Stmt`, and `A a = A a (B a)`, `B a = B (A a)`; group report, Dict/Set keys, hash law over all pairs | RUN (elm twin with hand-written comparisons) |
| a4bf-err-row-field | the review's M2 reproducer | CANNOT DERIVE "T : { r \| x : Int }" |
| a4bf-err-row-field-hash | `derive hash`, the open record behind an alias inside a `List` | CANNOT DERIVE "T > argument 2 > List element" |
| a4bf-err-open-record-compare, -hash, -inferred, -let | the review's F1 reproducers (annotated, `hash`, unannotated, in a `let`) | NO ATTACHED FUNCTION "Only a closed record" |
| a4bf-closed-record-later | `a has compare`/`hash` at a record whose row is open when the obligation is met (a lambda reads `a.x`) and closed later; a `let` function; an annotated closed record | RUN (elm twin with tuples) |
| a4bf-err-hash-shape, -hash-shape-arity2 | the review's F2 reproducers (`T -> String`, `T -> Int -> Int`) | CANNOT DERIVE with the written type |
| a4bf-err-beside-eq, -beside-eq-hash | the review's F3 reproducer (`Ci`), and `derive hash` alone | CANNOT DERIVE "its own `eq`" |

The review's scratch cases (`ficcus-tests/a4br`, 52) on elmficA4bf: the fixed ones are refused as above; every other case gives the
review's verdict unchanged (F4 `own-vector-member-fn`, F5 `phantom-wrapped`, F6 `value-at-comparable` still wrong rejects; P1
`row-var-eq-show` and the NaN sort order `float-ties*` still differ; the rest ok, ASan 0 live). `row-var-derive-fn` and
`-hash-fn` now get CANNOT DERIVE (M2) instead of TYPE MISMATCH / NO ATTACHED FUNCTION.

## 3. Deviations

1. **M1 (a): the bound is 200 nested derived types, not 2,000** (section 1).
2. **M1 (b) follows all unions of the group**, not only those that derive the member. A type of the group with a written member
   could stop the growth, but the deriver cannot see into a written body; refusing is the safe side and matches the self check.
3. **M2 also refuses the later structural members** (`toString`, `fromString`, `encode`, `decoder`), as the review suggested: the
   union shape has no row for them either.
4. **F1 also changes the unannotated and end-of-module reports** from AMBIGUOUS TYPE to NO ATTACHED FUNCTION with the closed-record
   paragraph: an open row is the reason, not an unknown type.
5. **F2 checks `compare` too** (already shape-checked as a well known name, so it should not fire there).

## 4. Not done here, and entanglement

* **F4** (a project's own `Vector`), **F5** (phantom through another type), **F6** (`comparable has compare`): untouched; their
  scratch cases behave as in the review.
* **P1** (the row lost in `==` and `Debug.toString` of `type T r = T { r | x : Int }`): untouched. M2's refusal is the stopgap the
  review proposed; lifting it waits on P1.
* **N8** (the unifier's "I do not know how to compare records" hint at an open record when the gate is open): not done; it is the
  unifier path (`a4b-err-open-record`, `open-record-sortwith`), not the obligation path F1 fixes.

## 5. Gates

2026-11-27, once at the end, on `elmficA4bf` (83d77f94): `BIN=elmficA4bf KEEP=1 S=/home/gordon/claude-tmp/gates-a4bf
ficcus-tests/gates.sh` (log /home/gordon/claude-tmp/gates-a4bf.log). All green:
* runtime 0; attach 378/0 (with `--rc`, ASan+UBSan, 0 live); derive 56/0; sized-fuzz 40/0; stringdiff all agree;
* types 267 PASS + 1 XFAIL; JS identity 28/0; examples 298 x3; fbip 0;
* effects-e2, e1review, effects-e1, e1p all ok; e1pr all ok (2 target rows); e1p-identity all ok;
* **a3b-identity against elmficA5c: 100 compiles, 0 differ** (the suite and e1p/effects C text, `--rc` and `--no-rc`, byte identical);
* e2review gates all ok (3 info, as before); rcfaults 2403/0 missed, rcfaults-big 239/0; rcgate-san ok; suite 16/16;
* typed 568 SAME + 12 BOTH_REJECT_SAME + 1 VERDICT_DIFF (salix-aws-spec, known); lib 108 PASS + 59 FIXED; elmdiff 1175 SAME, 0 DIFF.

## 6. Proposed text for the shared files (for the user or the planning chat)

* `docs/Ficcus-Design-Decisions.md`:
  > **DONE (27 Nov) A4bf (`feat/a4bf`, `elmficA4bf`, not merged; docs/attach/A4BF-NOTES.md):** the A4b review's M1 (the deriver
  > refuses a group of types that refer to each other at growing arguments; the specializer stops after 200 nested derived types as a
  > backstop), M2 (derive over an extensible-record field: CANNOT DERIVE until P1), F1 (`a has compare/hash` at an open record: NO
  > ATTACHED FUNCTION, closed records only), F2 (a written `hash`/`compare` of another type inside a derived one: CANNOT DERIVE),
  > F3 (`derive compare/hash` beside a written `eq`: CANNOT DERIVE). 15 a4bf cases (attach 378); gates all green, a3b-identity vs
  > elmficA5c 100/0. F4, F5, F6, P1 still open.
* `docs/PHASE1-CHECKLIST.md`: A4b review fixes done (M1, M2, F1, F2, F3); merge of feat/a4b + feat/a4bf pending.
