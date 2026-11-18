# H16 stage 1: answers to open questions 1-4 and 6 (by reading code; branch feat/known-pass)

Written for: the user and the sessions implementing W2 to W4. Line numbers are those of branch `ficcus`.

1. **A lifted clone referenced from a clone that is not its owner, or owned by a Value.** Yes. `mdLifted` is read only as `/= Nothing`
   (Free.hs:35, Twin.hs:53) and by Inline's `tOwner`, which only compares owners (`canCallDirect`, Inline.hs:260) and tolerates a missing owner.
   Rc, Borrow, RcCheck and CGen get captures from `Free.captures` by name (a use of `MGlobal l` brings `captures l` into `freeVars`, Free.hs:100),
   never from the owner. Not run as a separate five-line test: step 3 (gates with the pass on) and the scope checker cover it.
2. **`.mono` dumps** are written at Make.hs:183, straight after `Spec.specialize` and before Inline (and before Known). The expected `*.mono`
   files cannot change with the pass on.
3. **Position of function definitions in `mpClones`.** Does not matter for Functions: CGen declares all prototypes first (CGen.hs:159) and emits
   closure code before the bodies. Only Values need init order (global declarations are up front, initialisers run in list order, CGen.hs:171).
   Copies of Functions can go anywhere (W1 puts them after their origin); Values keep their relative order.
4. **Uniqueness of `mdName`.** Nothing assumes it. C names use the clone id (`functionName`, CGen.hs:288). `mdName` is used for messages
   (`siteName`, Rc `rsWhere`, RcCheck), Print, and rule U (`Vector.update`, Inline.hs:89 and Borrow.hs:85), which copies keep on purpose.
6. **Extra captured value parameters.** Borrow starts every reference parameter as `Borrowed` and weakens by use (Borrow.hs:75), so added
   parameters are inferred like any other; nothing special-cases them. Mismatched classes at a call make a parameter owned (Borrow.hs:76).

Consequence for the design: none of the answers invalidates it. One refinement: Inline's `canCallDirect` assumes a lifted callee is called only
inside its owner; that only matters for Inline's rule U, not for Known.
