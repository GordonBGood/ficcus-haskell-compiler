# A5a: the solver slice of A5 (inferred requirements, let generalization, defaulting, the monomorphism restriction)

Branch `feat/a5a` from `ficcus` 43068adc (A3b merged), 2026-11-26. Binary `bin/elmficA5a`. Design: `docs/A5-INFERENCE-DESIGN.md`
(sections 1 and 3; D1 to D4, D6, D9 as approved). Out of scope: selectors (A5b), texts and titles (A5c): every message
and title is the old one.

## What changed

| where | what |
|---|---|
| `Type/Requirements.hs` (new) | What each pending obligation becomes at a generalization; rule 1; defaulting; the carrier. |
| `Type/Solve.hs` | `CLet`: true ranks first (`adjustRanks`, the rank walk of `generalize` alone), then `Requirements.settle`, the carriers, the old `Members.defaulting` and `Members.hold` calls removed. `CLocal`: a name bound to a carrier is used like a constrained foreign function (`Members.use`). `discharge` runs rule 1 after each discharge. `runWith` takes the kinds of the definitions. |
| `Type/Members.hs` | `Obligation(..)` and `flexVariables` exported; `defaulting` removed (replaced). |
| `AST/Constraints.hs` | The inferred scheme `$where t $inferred ($has$m s u) ...` (`isInferred`), `hasTypeName`, the D6 marker name `name$inferred`. |
| `Compile.hs`, `Nitpick/Constraints.hs`, `builder/Generate.hs` | D6: a marker node per inferred constrained top level definition, a dependency of its node; the JavaScript output refuses it under CONSTRAINED FUNCTIONS with "Main.half (no type annotation: give it one with concrete types, such as `half : Float -> Float`, ...)". |
| `Canonicalize/Constraints.hs` | D2: a variable of a written `where` line is allowed when its subject is determined (closure from the type). AMBIGUOUS CONSTRAINT stays for an undetermined subject. |
| `Type/Dump.hs` | An inferred scheme has no hidden parameters (no member types in front of the instance). A relaxed `/ // modBy remainderBy` at a variable of its owner is recorded as a use (index 0). |
| `Ficcus/Mono/Marks.hs` | The relaxed operators are roots of the exact-key fixpoint (so `half x y = x / y` at two custom types gets two clones). |
| `Ficcus/Mono/Determined.hs` (new), `Ficcus/Mono/Spec.hs` | D2 in the specializer: `determinedByMembers` (at a call of a constrained function, the variables only a member decides, from the member of the subject's exact type) and `deadByMembers` (the same for the variables of a clone's body that are not in its key: `b` in an inferred `get2 w = get (get w)`). |

### Settling (Type.Requirements.settle)

Called at every generalization that has pending obligations, after the rank walk (so a variable made in the let but
part of an older structure counts as older). Let *outer* be the context's rank, *young* the definition's.

1. An obligation about an older subject: the young variables of its member type are raised to *outer* (B4).
2. For the young obligations (flexible subject of rank >= *young*), two closures under rule 3 (a determined subject
   determines its member type): from the member types of the older obligations (*by outer*), and from the variables of
   the header types plus the member types of obligations on the definition's own rigid variables (*by type*).
3. Each young obligation is:
   - *by outer*: held (subject and member type raised to *outer*);
   - else, for an untyped function (D4: arguments or a lambda body; a recursive group only when every member is one) and
     *by type*: into the scheme;
   - else in a `let`: held (a value, i.e. the MR; a typed definition; or an undetermined subject, which the top level then
     defaults or reports);
   - else (top level): defaulted (D3) or reported with the old texts (`Members.hold`'s report: MISSING CONSTRAINT when its
     variables are the definition's, UNKNOWN MEMBER TYPE otherwise).
4. A scheme obligation whose subject a hold reached is held too (no requirement is quantified while its subject is held).

Defaulting (D3): per subject, when the subject is a `number` variable, or a plain variable with a relaxed operator or
Float literal obligation: Float first when `div` or `fromFloat` is required (or the relaxed default is Float), else Int
first; the first of the two that `WK.builtinHas` every required member is unified with the subject, and the group is
discharged.

Carrier: for each header name, the scheme obligations whose subject its type determines, as
`$where type $inferred ($has$m s t) ...`, registered at the young rank before generalization. The environment maps the
name to it; `CLocal` copies it once (sharing kept) and `Members.use` turns the entries into obligations at the use. At the
top level the saved environment gives the interface scheme directly. Each name of a recursive group gets its own carrier
(the obligations its own type determines); recursive uses stay monomorphic.

Rule 1 (D9): after every discharge, two obligations with the same member on one flexible subject have their types
unified, and one is kept (an error is MEMBER TYPE MISMATCH, old title).

Elm programs: no `where` block means no pending obligation, so none of the new code runs except one `UF.get` per
`CLocal` (it checks for a carrier).

## Cases

`ficcus-tests/attach/a5agen.py --write` writes the cases and rows; `--expect` builds every twin (in `a5a-twins/`, on
`bin/elm0193` or `bin/elmficA3b`) and writes `expected.out`. Attach is now 285 cases (267 + 18).

### Section 3 rows that change (19)

| case | before (A3b) | A5a | twin |
|---|---|---|---|
| g71-q1-nosig-call | MISSING CONSTRAINT | RUN `(Money 4,Vec 2 4)` | oldc, `twice` annotated |
| g71-q1-nosig-call-one-use | MISSING CONSTRAINT | RUN `Money 4` | oldc |
| g71-q3-lifted-nosig | MISSING CONSTRAINT | RUN `(Money 4,Vec 2 4)` | oldc |
| g71-q4-two-locals-nosig | MISSING CONSTRAINT | RUN `(Money 3,GT)` | oldc |
| constraint-no-signature | MISSING CONSTRAINT | RUN `Money 1` | oldc |
| constraint-top-nosig-type | MISSING CONSTRAINT | RUN `1` | elm |
| constraint-top-nosig-hidden (D2) | UNKNOWN MEMBER TYPE x2 | RUN `1` | elm |
| g71-q3-let-two-types | TYPE MISMATCH | RUN `(Money 4,Vec 2 4)` | oldc, `g` lifted |
| constraint-let-fun-mono | TYPE MISMATCH | RUN `(1,T 2)` | elm |
| g71-q7-div-two | TYPE MISMATCH | RUN `(0.875,Cash 200)` | oldc |
| g71-q7-idiv-typed-int | TYPE MISMATCH | RUN `(2,Cash 200)` | oldc |
| g71-q7-idiv-lifted-nosig | TYPE MISMATCH | RUN `(2,Cash 200)` | oldc |
| g71-q7-idiv-lifted-sig (L5) | MISSING CONSTRAINT | RUN `(2,Cash 200)` | oldc |
| g71-q7-idiv-two (L4) | RUN `(Cash 200,Cash 200)` | RUN `(2,Cash 200)` | oldc |
| g71-q7-modby-two (L4) | RUN `(Cash 100,Cash 100)` | RUN `(1,Cash 100)` | oldc |
| a3-err-ambiguous-literal (D3) | UNKNOWN MEMBER TYPE | RUN `6` | oldc, typed list |
| a3-f7-err-literal-obligation (D3) | UNKNOWN MEMBER TYPE | RUN `2` | oldc, typed value |
| constraint-ambiguous (D2) | AMBIGUOUS CONSTRAINT | RUN `"1"` | elm |
| a3-f8-err-let-div-two-types | TYPE MISMATCH | NO MEMBER (`div : Int -> Int -> Int`) | |

The converted RUN rows are `RUN c`: in JavaScript they are refused (D6, or a constrained function as before).

Unchanged as the note says: constraint-let-poly and constraint-order-bad-* (MR), q7-div-cash-only, a3-known-let-div, the
G71 B3/B4 cases, every other RUN case. q2-missing-all, q2-missing-one, q1-nosig-bare-member stay NAMING ERROR (A5b).

**The A3b Float literal rule under D3**: no existing case changed (all 15 a3b-* rows and the converted A3b rows pass
as before; a3b-fromfloat-defaults still runs in JS and C). What changes is an *unannotated function* with a Float literal
in a module that sees a type with `fromFloat`: `scale x = x * 0.5` used to default its literal to Float (so `scale` was
`Float -> Float` and ran in JavaScript); it now infers `number has fromFloat` and works at Float32 and Float
(a5a-float-literal: `("1.5",1.5)`), and the JavaScript output refuses it (D6). A Float literal in a top level *value*
still defaults to Float (Float first when `fromFloat` is required).

### New cases (18)

| case | rule | result |
|---|---|---|
| a5a-top-infer-two-types | D1, inferred through an inferred scheme | RUN `(Money 8,Vec 4 8,Money 10)` |
| a5a-top-infer-recursive | D1, recursive function | RUN `(Money 4,Vec 2 4)` |
| a5a-cross-module | D1, scheme through the interface | RUN `(Money 4,Vec 2 4)` |
| a5a-js-inferred | D6 | REJECT CONSTRAINED FUNCTIONS "Main.half (no type annotation" |
| a5a-subject-decides | rules 2, 3 (`get2 w = get (get w)` inferred) | RUN `(42,T 5,3)` |
| a5a-b2-chain | D2, a chain `a has f : a -> b`, `b has g : b -> String` | RUN `"T7"` |
| a5a-b4-held-generic | B4 in an inferred function | RUN `((1,1),(T 2,T 2))` |
| a5a-let-two-types | L2, own and held requirement in one let function | RUN `((Money 2,Money 2),(Vec 2 4,Money 2))` |
| a5a-let-outer-determined | hold by determination | RUN `((5,Money 2),(5,Vec 2 2))` |
| a5a-let-lambda | D4, lambda body is a function | RUN `(Money 4,Vec 2 4)` |
| a5a-let-rem-two | L3, `remainderBy` | RUN `(1,Cash 100)` |
| a5a-div-two-customs | relaxed `/` at two custom types (exact keys) | RUN `((Cash 200,Ratio 4 6),(Cash 3,Ratio 1 2),1.5)` |
| a5a-mr-let-value | D4 (MR) in a let | TYPE MISMATCH |
| a5a-mr-top-value | D4 (MR) at the top level | MISSING CONSTRAINT (`pl : a -> a -> a`) |
| a5a-default-top-value | D3, Int and Float | RUN `(3,1.5,(3.5,3,1))` |
| a5a-undetermined-error | D3, a non-number undetermined subject | UNKNOWN MEMBER TYPE |
| a5a-float-literal | D3 and the A3b literal | RUN `("1.5",1.5)` (C only: Float32) |
| a5a-rule1-poly-member | D9 (rule 1) | MEMBER TYPE MISMATCH |

L5 is covered by g71-q7-idiv-lifted-sig and a5a-default-top-value; L2 by g71-q3-let-two-types and a5a-let-two-types; L3
by g71-q7-div-two and a5a-let-rem-two; L4 by g71-q7-idiv-two and g71-q7-modby-two; B2 by constraint-ambiguous and
a5a-b2-chain; B4 by the G71 b4 cases, constraint-order and a5a-b4-held-generic.

## Deviations from the note

1. **constraint-no-members-at-all stays rejected** (UNKNOWN MEMBER TYPE). The note's section 3 table says RUN `3`, but its
   own L5 row and D3 say a literal whose requirements Int and Float cannot meet (`sum [ 1, 2 ]` needs `zero`) remains an
   error. I followed D3.
2. **An undetermined subject in a `let` is held, not defaulted or reported at the let.** It reaches the top level (its
   variables have the context's rank), where it is defaulted or reported. The results are the same; the error points
   at the top level definition's use, and a let never defaults by itself.
3. **One carrier per name of a recursive group**, with the obligations that name's type determines (not one shared
   carrier): a use of one name then does not get requirements about variables of another name's type.
4. **The specializer needed more than "marks roots from inferred schemes"**: an inferred function only constrained through
   a relaxed operator has no constrained callee to propagate from, so the relaxed operators became roots of the
   exact-key fixpoint (Dump records the use), and determined variables that are not in a clone's key are found by
   `deadByMembers` before the body is specialized.
5. The rank walk of `generalize` runs twice for a definition with pending obligations (once before settling, once in the
   generalization itself). Never for an Elm program.

## Open points for the Opus review

- The carrier copy keeps sharing: one `makeCopy` of the `$where` structure; check with a requirement whose type mentions
  an outer (non-generic) variable (a5a-let-two-types has one: `plus m m` held, `plus x x` in the scheme).
- The hold is the closure from the older obligations' member types; a young subject that is *structurally* inside an older
  variable is caught by the rank walk before settling (`adjustRanks`). Worth a look: whether anything else can make a
  young subject outer that neither covers.
- Order at the top level: rule 1 (in each discharge), then settle (hold / scheme / default), then `Members.sweep` after
  the generalization; the A3c rank rule (top level definitions always generalize) is unchanged.
- One subject type gives the same member in every module: discharge looks up `Members.typeId` in the table, unchanged.
- `Requirements.improve` reports a rule 1 conflict as `BadMember ... (MemberOfVariable "a")`: the variable name is a
  placeholder and the text says "this type annotation" for an inferred requirement (A5c).
- The MR at the top level (a5a-mr-top-value) reports MISSING CONSTRAINT with "I never infer constraints", now untrue (A5c).
- `determinedByMembers`/`deadByMembers` only look at custom-type subjects (not built-in or sized types, whose members have
  fixed shapes); a determined variable through a built-in member would still be a `ref` key.
- D6 marks every inferred constrained top level function, used or not, in a module compiled to JavaScript (as a written
  one is).

## Gates

2026-11-26, `BIN=elmficA5a KEEP=1 ficcus-tests/gates.sh` (log /home/gordon/claude-tmp/gates-a5a.log), all green:
runtime 0; attach 285/0 (with `--rc`, ASan+UBSan, 0 live); sized-fuzz 40/0; stringdiff all agree; types 267 PASS + 1 XFAIL;
JS identity 28/0; examples 298 x3; fbip 0; effects-e2, e1review, effects-e1, e1p all ok; e1pr all ok (2 target rows);
e1p-identity all ok; **a3b-identity against elmficA3b: 100 compiles, 0 differ** (the C text of the 16 suite programs and
the e1p/effects programs, `--rc` and `--no-rc`: the section 3 claim that programs without a `where` block are unchanged);
e2review gates all ok (3 info, the recorded notes); rcfaults 2403/0 missed, rcfaults-big 239/0; rcgate-san ok; suite 16/16;
typed 568 SAME + 12 BOTH_REJECT_SAME + 1 VERDICT_DIFF (salix-aws-spec, known); lib 108 PASS + 59 FIXED; elmdiff 1175 SAME,
0 DIFF.
