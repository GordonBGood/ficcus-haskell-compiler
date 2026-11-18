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
  `mdLifted = Just owner` (`specLambda` Spec.hs:1021-1028 returns `MGlobal lamId` with `CRef`; local functions Spec.hs:803, 859). There is no
  `MLam` in practice after Spec (the constructor exists, Ir.hs:~47, but `specLambda` never builds it).
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
| **compile-time top-level constants** (FIX3) | `CGen.constText` CGen.hs:207, `constOf` :218 (fuel 40) | CGen, per use: `MGlobal c` of a non-function whose body is a literal Int/Float/Char/enum or Int arithmetic/bit ops on constants (CGen.hs:158, 552) | only scalars; no String, record, list, constructor values; no Float arithmetic folding beyond literals (to be checked); no folding across function calls |
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
lifted clone passed as a parameter) into a direct call; unbox results (a result is one `Class`; a pair result is a `CStruct` returned by value
but a custom-type result is always a heap object); scalar-replace a constructor that is bound by `let` and matched later in a different expression.

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
  `fic_apN` checks the arity of the closure at run time (partial application, over-application) in `runtime/fic_closure.h` (checked in section 3 of step 2).
* **Closure object** `{ header{rc,tag=FIC_TAG_CLOSURE,nptr,cls}, const fic_code *code, captured values... }`, type `fic_k_<classtags>` from `capType` :665;
  `fic_code = { entry, arity [, own_entry] }` static (CGen.hs:765). Entry stub `<clone>_stub(self, fic_word a0..)` (CGen.hs:~710) unpacks words to the
  clone's parameter classes (a struct is boxed in the word), reads captured values from `self`, calls the real function. A clone with no captures has a static
  immortal closure `fic_clo` (CGen.hs:767) used by every value reference; one with captures allocates at each `closureValue` (:773-790, `fic_alloc` + field stores).
* **Where it is decided that a call is known**: only syntactically, in CGen, by the head being `MGlobal` of a Function clone with matching arity. The
  specializer decides what the head is: a name resolving to a clone (`specCall'` Spec.hs:927, `RClone`) gives `MGlobal`; a local variable
  of function type, or a parameter, gives `MLocal`, hence `unknownCall`. After Inline there is no pass that turns `MLocal f` into `MGlobal` when `f` is bound to a known lifted clone.
