# H16 survey: the compiler after type checking (facts only, no design)

Written for the Opus design note on "stage 1: known function specialization with inlining" (later stage 2: case of known
constructor, unboxed results, scalar replacement). Branch `design/h16-survey`, from `ficcus`. All line numbers are those of
branch `ficcus` at 2e5f3b16. Paths are relative to `ficcus-haskell-compiler/`. `M.` = `compiler/src/Ficcus/Mono/`.

## 1. The pipeline after type checking

The C back end does NOT use Elm's `Optimize/*` or `AST.Optimized` (those are the JS path: `Generate.JavaScript`). It starts from the
**Canonical** tree plus the recorded types of the type checker.

| # | stage | module (lines) | in -> out | main types |
|---|-------|----------------|-----------|------------|
| 0 | record | `builder/src/Ficcus/TypesFile.hs:29-30` (`Modules.register`, `Facts.register`), `M.Modules`(101), `M.Facts`(86), `Type/Dump`(in `compiler/src/Type`) | each project module, while compiled (flag `--output=x.c` sets `keepModules`, `compiler/src/Ficcus/Flags.hs`) | `ModuleData` (Canonical module + recorded types), `ModuleFacts` (schemes, kinds, substitution at each use, init order) |
| 1 | marks | `M.Marks`(92), `M.Members`(107) | facts -> `Marks` (which type variables need exact types: number, comparable, equatable, printed) | `Marks` |
| 2 | specializer | `M.Spec`(1186) `specialize` :181 | Canonical + marks -> `MProgram` | `MProgram{mpClones,mpMain,mpUnions}` (`M.Ir`:~150), `MDef`, `MExpr{mRep::Class, mNode::MNode}`, `MNode` (Ir.hs:41-73), `Class` = CI64/CF64/CU32/CEnum/CUnit/CRef/CStruct (`M.Class`), `Key`/`KeyPart` (specialization key) |
| 3 | inliner | `M.Inline`(688) `inlineProgram` :75 | `MProgram` -> `MProgram` | same IR; see section 2 |
| 4 | twin | `M.Twin`(85) `twinProgram` | `MProgram` -> `MProgram` | adds `mdTwin`/`mdCapsOwned` clones (owned-capture copy of a lifted clone) |
| 5 | borrow inference | `M.Borrow`(439) `inferBorrow` (called from `M.Rc:83`) | clones -> clones with `mdOwn :: [Own]` | `Own = Owned \| Borrowed` per parameter |
| 6 | Rc (Perceus dup/drop) | `M.Rc`(808) `rcProgram` :80, helpers `M.Reuse`(154) | `MProgram` -> `MProgram` with RC nodes | adds `MDup`, `MDrop`, `MUnpack`, `MSpec`, `MReuse`, `MFreeTok`, `MOwn` (Ir.hs:62-73) |
| 7 | checker | `M.RcCheck`(472) `rcCheck` | counted program -> error list | |
| 8 | C generator | `M.CGen`(2509) `generate` , `M.Layout`(174), `M.Free`(105), `M.Kernel`(294), `M.CRuntime`/`M.Embed` (runtime C text) | `MProgram` -> C text | `Info{iClones, iCaptured, iUnions}` (CGen.hs:122) |

Driver: `terminal/src/Make.hs:183-223` (`Just (FicC target)`): `Spec.specialize` :189, then
`Rc.rcProgram (Twin.twinProgram (Inline.inlineProgram program)) >>= mutated` :208, then `RcCheck.rcCheck` :217, then `CGen.generate rcMode` :221.
`rcMode = not noRcFlag && (rcFlag || rcDefault)` :120 and `rcDefault = True` :84, so Inline, Twin, Borrow and Rc run by default;
with `--no-rc` the specializer output goes straight to `CGen` (this no-RC C text is the "oracle" for the norc identity checks).

* **Perceus insertion**: `M.Rc.rcProgram` only (Mono -> Mono). Convention doc: Rc.hs:11-33. Everything before it is count-free.
* **Lambda lifting**: done in the specializer, not later. Every lambda and local function becomes a top-level `MDef` with
  `mdLifted = Just owner` (`specLambda` Spec.hs:1021-1028 returns `MGlobal lamId` with `CRef`; local functions Spec.hs:803, 859). `MLam` exists in the IR (Ir.hs:48) but `Spec.hs` never builds it (no occurrence in Spec.hs), so no pass ever sees a lambda *expression*: only `MGlobal lamId`.
  The *captured variables* are NOT in the IR: they are computed afterwards by `M.Free.captures` :32 (called from `CGen.hs:122` and `Rc.hs:85`,
  `Twin.hs`) as a map `CloneId -> [(name, Class)]` and passed to a lifted clone as extra leading C parameters (`CGen.hs:557`: `caps ++ vals`).
* **Partial application**: `partialApp` Spec.hs:988: the supplied arguments are bound to locals and a lifted lambda `\x y -> f a b x y` is made
  (clone of its own); a partial application of a kernel or constructor is a lifted lambda too (Spec.hs:970, 978, 980). So at runtime a PAP is an
  ordinary closure object with captured values, not a special `fic_pap`.
* **Defunctionalisation**: none. Closure = heap object with a code pointer (section 3).
* **Init order of top-level values**: `Spec.ordered` Spec.hs:222-258 (dependency-first DFS; cycles of >=2 values from `lazy`-style parser
  combinators are emitted together, in eager-reference order, FIX2). `mpClones` is "in initialisation order, main last" (Ir.hs:~125). Lifted
  clones that are only made into closures are not dependencies (Spec.hs:224-226, `eagerRefs` :261).

## 2. Existing optimisation passes

| pass | where | trigger | cannot do now |
|------|-------|---------|---------------|
| **Inliner / known-constructor** (rules A, B, T, L, U) | `M.Inline` | always with `--rc` (default); `FICCUS_NO_INLINE=1` off (Inline.hs:51); not run with `--no-rc` | see list below |
| **compile-time top-level constants** (FIX3) | `CGen.constText` CGen.hs:207, `constOf` :218 (fuel 40) | CGen, per use: `MGlobal c` of a non-function whose body is a literal Int/Float/Char/enum or Int arithmetic/bit ops on constants (CGen.hs:158, 552) | only scalars; Int ops (add, sub, mul, negate, Bitwise64.*) are folded, Float arithmetic is not (constOf CGen.hs:236-239); no String, record, list or constructor values; no folding across function calls; done in the C generator, so it is invisible to the IR passes |
| **init-order fix** (FIX2) | `Spec.ordered` Spec.hs:222 | always, in the specializer | only orders top-level values; does not make a cycle through a lazily-referenced lifted function a non-cycle at runtime (it relies on the lifted clone being only a closure) |
| **Twin** (closure steals captured values) | `M.Twin` | `--rc` only; `FICCUS_NO_CLO_STEAL=1` off | works on closure *objects* made from lifted clones; does not remove the closure |
| **Reuse / drop specialization** | `M.Reuse`, `M.Rc` (MSpec, MReuse) | in the Rc pass | constructor cell reuse only; not scalar replacement |
| **Elm's `Optimize` (decision trees, case-of-case in JS)** | `compiler/src/Optimize/*` | JS path only | not used by the C path |

There is no general constant folding, no case-of-case in the Elm sense, no dead-code pass beyond reachability from `main` (`Spec` only
requests clones that are reached; `Inline` drops unreferenced `Vector.update` clones, Inline.hs:83-87).

The inliner (Inline.hs:1-48 header, `table` :93, `rw` :201) in detail:
* **Rule A** `case E of ..` where E is a call of a *producer* (small, non-recursive function all of whose leaves are constructor applications or
  producer calls) or an expression whose leaves are constructor applications: the producer body replaces the call and the `case` is pushed into the
  leaves (`ruleA` :420, `push` :554). This is known-constructor with case-of-case on constructor leaves.
* **Rule B** a *consumer* (small function whose body is a `case` on one parameter) applied to such an expression (`ruleB` :322).
* **Rule T** two-tuple scrutinee form (`ruleT` :297). **Rule L** `Vector.fromList [..]` literal -> `withCapacity`/`push` chain (:217-228).
* **Rule U** (:231-240): `Vector.update i f v` with `f` a known lifted lambda of the same definition is written out so that `f x` is a direct
  call. This is the ONLY place where a closure argument is specialised away today, and it is hard-wired by name (`updateName` :255).
* Eligibility (`table` :93-105): `mdKind == Function`, not lifted, not the owner of lifted clones, body `size <= 80` (`sizeLimit` :70),
  not self-recursive, **`not (hasLam b)`** (no lambda or local function inside), no record patterns, refers to no lifted clone.
  So any combinator whose body builds a lambda (`map2 f pa pb = \s -> ...`, parser combinators) is NOT inlinable today.
* `instantiate` :509 / `freshen` :644 / `substitute` :623 do renaming-correct copying of bodies; `fresh` :603 is the name counter (state `(Int,Int,Int)`).
* Evaluation order preserved by `let`-binding non-atomic args (`atom` :183); `quietIn`/`tQuiet` (:118) tracks clones that cannot print
  (`Debug`), so reordering is allowed only across them.

What none of them can do: inline a function whose body contains a lambda; inline a recursive function; specialise a clone on a known
function argument in general (rule U excepted); turn a call through a closure value (`MCall h args` with `h` an `MLocal`/`MGlobal` of a
lifted clone passed as a parameter) into a direct call; unbox results (a result is one `Class`; records and tuples are `CStruct` values, but every custom-type result, e.g. `Step a`, is a heap object); scalar-replace a constructor that is bound by `let` and matched later in a different expression.

## 3. How a call to a function value is generated

Decision point: `CGen.genExpr`, the `MCall` cases at CGen.hs:556-565 (value position) and :478-496 (tail position, with self tail call -> `continue`).
Order of tests: `MKernel` head -> `kernelCall`; `MGlobal c` head where the clone is a Function and `length args == length (mdParams d)` -> **direct
C call** `functionName d(caps..., args...)`; `MCtor` head -> allocate; anything else -> `unknownCall` :798 -> `closureCall` :801.

* **Known top-level call**: `f(arg, ...)`, C function named by `functionName d`; a lifted callee gets its captured variables prepended (`iCaptured`).
  Arguments are converted by `atomsTo` :819 / `adaptOwn` to the parameter classes (unboxed i64/f64/u32 or struct by value).
  A direct call needs no closure object: `closureRefs` CGen.hs:633 lists only clones used as *values* or called with a wrong arg count.
* **Unknown call**: `fic_apN(f, mask, w0, .., wN-1)` (`closureCall` :801-812), N = 1..9 (`maxArity` :628); `mask` has bit i set when argument i is a
  reference (so the runtime can count it); arguments are packed to `fic_word` (a union: `.i .d .c .b .p`, `wordSel` :655) and the result unpacked by
  `wordSel cls`. `_own` variant `fic_apN_own` when the call consumes the function value (S6, `closureCall True`, chosen by the Rc pass/steal rules in `M.Borrow:158`).
  `fic_apN` checks the arity of the closure at run time (partial application, over-application) in `runtime/fic_closure.h` (`runtime/fic_closure.h:9-12`).
* **Closure object** `{ header{rc,tag=FIC_TAG_CLOSURE,nptr,cls}, const fic_code *code, captured values... }`, type `fic_k_<classtags>` from `capType` :665;
  `fic_code = { entry, arity [, own_entry] }` static (CGen.hs:765). Entry stub `<clone>_stub(self, fic_word a0..)` (CGen.hs:~710) unpacks words to the
  clone's parameter classes (a struct is boxed in the word), reads captured values from `self`, calls the real function. A clone with no captures has a static
  immortal closure `fic_clo` (CGen.hs:767) used by every value reference; one with captures allocates at each `closureValue` (:773-790, `fic_alloc` + field stores).
* **Where it is decided that a call is known**: only syntactically, in CGen, by the head being `MGlobal` of a Function clone with matching arity. The
  specializer decides what the head is: a name resolving to a clone (`specCall'` Spec.hs:927, `RClone`) gives `MGlobal`; a local variable
  of function type, or a parameter, gives `MLocal`, hence `unknownCall`. After Inline there is no pass that turns `MLocal f` into `MGlobal` when `f` is bound to a known lifted clone.

## 4. The combinator style P1 program

Source: `targets/p1/src/JsonComb.elm` (632 lines; library lines 44-~330: `succeed` :44, `problem` :49, `map` :54, `map2` :65, `andThen` :81, `oneOf` :107,
`oneOfHelp` :112, `lazy` :131). `type alias Parser a = State -> Step a` is a plain function type; `Step a = Good Bool a State | Bad Bool String`;
`State = { src : Vector Int, offset : Int }`. Every combinator is `combinator args = \s -> ...`.
Its own `JsonComb*` siblings: only `JsonComb.elm` and `JsonStrComb.elm` (String version) are combinator style.

The excerpt below is NOT cut from JsonComb: it is a 50-line stand-alone `Mini.elm` with the same definitions (`State = {off:Int}`, `succeed`, `map2`, `oneOf`,
`oneOfHelp`, `item = \s -> Good True s.off {off = s.off+1}`, `pair = map2 (\a b -> a + b) item item`, `top = oneOf [ pair, succeed 7 ]`).
Generated with `bin/elmficA16 make src/Mini.elm --output=x.c --rc` (default flags: Inline, Twin, Rc on). Clone ids c4.. are the specializer's. Output reformatted only by
removing `(void)` lines in `map2`.

```c
/* c9 Mini.map2   key: (v0=i64; v1=i64; v2=i64) */                   // the combinator: builds the parser, runs nothing
static fic_ref f9_map2(fic_ref v_f, fic_ref v_pa, fic_ref v_pb) {
  fic_k_ppp *k45 = (fic_k_ppp *)fic_alloc(sizeof(fic_k_ppp), FIC_TAG_CLOSURE, 3);   // (A) closure for `\s -> ..` of map2
  k45->code = &code13;  k45->r0 = v_f;  k45->r1 = v_pa;  k45->r2 = v_pb;          //     captures f, pa, pb
  return (&k45->h);
}
/* c13 Mini.lambda@17:5   lifted-from: c9 */                          // the body of `\s -> ..`
static fic_ref f13_lambda(fic_ref v_f, fic_ref v_pa, fic_ref v_pb, fic_s_i v_s) {
  fic_o_SiE *o31 = (fic_o_SiE *)fic_alloc(sizeof(fic_o_SiE), FIC_TAG_BOX, 0);       // (B) the state struct is boxed to go through a word
  o31->s0 = v_s.f0;  fic_ref a32 = (&o31->h);
  fic_ref v_rc_3 = fic_ap1(v_pa, 1u, fic_w_p(a32)).p;                               // (C) `pa s` : unknown call; result `Step` is a heap object
  ... if (tag == 1u /* Good */) { ... fic_ap1(v_pb, ...) ... fic_ap2(v_f, 3u, a, b) ... build `Good` (fresh cell or reuse token) ... }
}
/* c10 Mini.lambda@38:14 */  static int64_t f10_lambda(int64_t v_a, int64_t v_b) { return FIC_ADD64(v_a, v_b); }   // `\a b -> a + b`, direct, unboxed
/* c5 Mini.pair */
static fic_ref val5_pair(void) {                                                     // runs once at start up
  fic_ref u80 = (&clo10.h); fic_dup(u80); fic_ref a81 = u80;                         // (D) static closure of the lambda (no captures: no allocation)
  fic_dup(g11_item); fic_ref a82 = g11_item;  fic_dup(g11_item); fic_ref a83 = g11_item;  // (E) `item` is a global VALUE holding a closure
  return f9_map2(a81, a82, a83);                                                     // (F) known direct call of map2 (the only known call here)
}
/* c2 Mini.top */
static fic_ref val2_top(void) {
  fic_ref a84 = g5_pair;  fic_ref a85 = f6_succeed(INT64_C(7));                      // (G) succeed 7 : another closure (captures 7)
  ... fic_alloc(fic_o_pp) x2 ...                                                     // (H) the list cells of [pair, succeed 7]
  return f4_oneOf(a88);                                                              // (I) oneOf builds a closure capturing the list
}
```

Which compiler decision produces each allocation or indirect call:

* **(A) `map2`/`oneOf`/`succeed` closure**: `Spec.specLambda` (Spec.hs:1021) lifts `\s -> ..` to a clone with `mdLifted = Just map2`, and returns `MGlobal lamId` (class `CRef`);
  `CGen.genExpr` `MGlobal c` of a Function clone -> `closureValue` (CGen.hs:773): static `fic_clo` when `captures` (Free.hs:32) found no captured variables (D), otherwise `fic_alloc`
  of `fic_k_<tags>` (capType :665) + field stores. The captured set comes from `M.Free.captures`, after Inline, so the inliner cannot see it.
* **(B) boxing of `State`**: `fic_s_i` is a struct-class value; a closure entry takes `fic_word`s, so a struct argument of an unknown call is boxed (`abiClass = boxedClass` CGen.hs:651,
  `closureCall` :801-812 via `atomsTo`). Decision: CGen's closure ABI, taken at every `fic_apN` and every `_stub`.
* **(C) the `fic_ap1` calls**: the head `pa` is an `MLocal` parameter, so `specCall'` (Spec.hs:927) gives `MCall (MLocal ..)` and CGen.hs:565 sends it to `unknownCall`. Nothing in Inline
  looks through it, even though at the only call site (`pair`) the argument is the known clone `item`.
* **(D)** `clo10`: capture-free lifted clone used as a value (CGen.hs:767). **(E)** `g11_item`: top-level *value* of function type, initialised by `val11_item` (a lambda bound to a
  top-level name with no parameters is a `Value` clone, `DefKind`, not a `Function`), so a use of `item` is a global load plus `fic_dup`, never a direct call. `constText` (FIX3) does not
  apply (not a scalar).
* **(F)** `f9_map2` is a direct call (`MCall (MGlobal c) args`, arity 3 = 3 params, CGen.hs:557), but `map2` has 3 parameters and returns a closure; Inline does not expand it because `hasLam` (Inline.hs:140, used at :99).
* **(G, H, I)**: ordinary constructor/list allocations (CGen.hs:537-545, 561) and a closure allocation by (A).
* A **partial application** such as `map2 f` would be `Spec.partialApp` (Spec.hs:988): a lifted lambda that captures `f` (closure allocation by (A)).
* Twin (S7 part 3) additionally produced `c15`/`c16` copies (`f15_lambda`, `f16_lambda`: lines 2171, 2176 of x.c) of the lifted lambdas of `oneOf`/`map2` whose captured values are owned; used only
  by `fic_apN_own` entries (CGen.hs:~740 `_own` stub).

JsonComb's recursive rules are functions of `()` (`lazy (\_ -> ..)`, JsonComb.elm:131) because of the init-order bug documented in `docs/P1-JSON.md` item 1 (see `Spec.ordered`, FIX2, which
came later; untested here whether the cyclic form now works).

## 5. Hooks for a pre-C specialization pass

Today's composition (Make.hs:208): `Rc.rcProgram (Twin.twinProgram (Inline.inlineProgram program)) >>= mutated`, with `program` the output of `Spec.specialize`. A new pass `MProgram -> MProgram`
fits in three places:

1. **Between `Spec.specialize` and `Inline.inlineProgram`** (Make.hs:208, one line). It receives the full `MProgram` with lifted clones as separate `MDef`s, `MGlobal` heads, `MLocal` heads for unknown
   calls, no counts, no ownership (`mdOwn = []`), no captures (they are computed on demand by `Free.captures`, which is a pure function of the clone list, so the pass can call it).
   Reason to prefer this place: the inliner and its rules (A, B, T) then see the expanded bodies; the known-constructor machinery of stage 2 is already there (`ruleA`, `push`, `instantiate`,
   `freshen`, `substitute`, `descend` give a body-copying kit with fresh-name state).
2. **Inside `Inline.rw`** as a new rule in the style of rule U (Inline.hs:231-240): `MCall (MGlobal c) [.., MGlobal l, ..]` where `c` is a small function and `l` a known lifted lambda. It already has `canCallDirect`
   (:260), `tDefs`, `instantiate`. Smallest change for stage 1, but `table`'s `not (hasLam b)` (:99) forbids exactly the combinators (`map2` returns a lambda) so the eligibility has to change.
3. **After Inline, before Twin** (Twin only reads `mdBody` and `valueRefs`).

Data it would handle: `MDef` (Ir.hs:102-123: `mdBody :: Maybe MExpr`, `mdParams :: [(String, Class)]`, `mdLifted`, `mdKey`), `MExpr{mRep, mNode}`, node forms `MCall`, `MGlobal CloneId`, `MLocal`, `MLetVal`, `MCase`
with `MPat` (`PCtor name tag args`, `PVar`, ...), `MKernel`, `MCtor`. A known function value at a call site appears as `MGlobal l` with `l` a clone with `mdLifted /= Nothing` or a top-level Function clone;
captured variables of `l` are NOT arguments, they are free names resolved by name in the owner's scope (`Inline.hs:98` rejects bodies that refer to lifted clones for this reason, `tLifted`/`tOwner`).
A call of a lifted clone that captures variables needs those variables in scope at the new call site, i.e. the specialised copy must live inside (or be parameterised over) the owner.

**Perceus ordering constraint**: the pass must run before `Rc.rcProgram`. Dup/drop are inserted only there, `Borrow.inferBorrow` (ownership of parameters) is run at Rc.hs:83 on the clones it is
given, and `RcCheck` verifies the result, so a pass after Rc would have to maintain counts by hand. A pass before it can create/duplicate clones freely (new clones need `mdOwn = []`,
`mdTwin = Nothing`, fresh `CloneId`s: `Twin` uses `1 + maximum CloneId`, Twin.hs:~56) and the output order must stay a valid init order (`mpClones` is "in initialisation order").

**Unsure of**:
* whether a pass before Inline should be gated on `rcMode` as Inline is (the no-RC text is the byte-for-byte oracle of `norc_identity.py`, so a new pass that also ran with `--no-rc` would change
  the sha256 of all 16 programs; Inline avoids this by running only inside the `rcMode` branch, Make.hs:208 - in that line `rcMode` is the condition: `if rcMode then ... else Right program`).
* how mutually recursive lifted clones, and top-level *values* of function type (E above; `item`, `pair`), should be treated: a value clone is initialised once, so it is a candidate for "known" but `mdKind = Value`.
* the interaction with `mdInit`/`mdNeeds` (set to `Nothing`/`[]` by Spec at Spec.hs:337 and apparently only used for ordering inside `Spec.ordered`; I did not find a later reader).
* the key space: Spec clones by `Key` (type); a pass that clones a function per known closure argument has no `Key` for "specialised on l", so a new clone needs either a new `Key` part or a name.
* code size / compile time limits: only `sizeLimit = 80` in Inline and `keyLimit` in Spec (Spec.hs:66) exist.

## 6. Test and gate hooks, and switching a pass off

Gates (`ficcus-tests/gates.sh`, about one hour, serial; header lists expected numbers): runtime (`runtime/test.sh`), attach (79 cases), stringdiff, types (267 PASS 1 XFAIL), jsid (28),
examples x3 (plain, `FIC_DROP_ALL=1`, `FICTEST_RC=1 FICTEST_SAN=1`), fbip (`fbip_check.py`), rcfaults and rcfaults-big (`rccheck_faults.py`, mutation of dup/drop via `FICCUS_RC_MUTATE`), rcgate-san
(`rc_gate.py --san`), suite (`targets/run_all.py --san`: the 16 programs against Elm's golden outputs), typed (568/12/1), lib-rcsan (`libsuite.sh rcsan`), elmdiff (1160 SAME + 15 apps).
Others: `ficcus-tests/norc_identity.py` (SHA-256 of the no-RC C text of the 16 programs against `ficcus-tests/expected/norc_identity.sha256`; refresh only with `--update --reason`),
`ficcus-tests/rcfuzz.py` (random well-typed programs; `--settings` selects an experiment switch, `noinline` = `FICCUS_NO_INLINE`), `v2fuzz.py` (compares `--no-rc` with `--rc` under ASan),
`p1_bench.py` (`tools/p1_bench.py`/`ficcus-tools/p1_bench.py`: the combinator program, allocation counters through `FIC_STATS`), `targets/` suite for the differential comparison against Elm.
`ficcus-tests/expected/*.mono` are the `--output` Mono dumps of the suite (`Print.renderProgram`, `M.Print`), the natural place to see whether a pass changed the IR.

Switches: each pass reads a process-wide environment variable once through `unsafePerformIO (lookupEnv ..)`: Inline `FICCUS_NO_INLINE=1` (Inline.hs:51), Twin `FICCUS_NO_CLO_STEAL=1` (Twin.hs:41), Rc
`FICCUS_NO_SPEC`, `FICCUS_NO_REUSE`, `FICCUS_NO_STEAL`, `FICCUS_NO_ALIAS_LET`, Borrow `FICCUS_NO_STEAL_RULE`, `FICCUS_BORROW_*` (list in the workspace `docs/FLAGS.md`, section 4, and `rcfuzz.py:27-33`, which has one
setting per switch). Command line flags: `--rc`/`--no-rc` (Make.hs:120; `Flags` are defined in the `terminal` package's `Flags` record, `Make.hs:107` pattern). A new pass would follow the same pattern
(`FICCUS_NO_<NAME>=1`, plus a line in `rcfuzz.py`'s list and in `docs/FLAGS.md`) and a variant row in the gates. Debug aids: `FICCUS_RC_DUMP=text` prints the counted clones whose name contains the text
(Make.hs:~212), `FICCUS_TWIN_STATS=1` prints counters; `Inline.inlineStats` returns the rule counts (a new pass would want the same).
The binary of a gate is `bin/elmficNN`; the build is `cabal -j1 build exe:elm --ghc-options="+RTS -M6g -RTS"` (not run for this survey).
