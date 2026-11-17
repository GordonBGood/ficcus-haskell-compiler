# PROGRAMS session: differences found that are NOT divergences (decided behaviour or Elm bugs)

Programs: `ficcus-tests/programs/NN-name/` (run with `ficcus-tests/programs/run.py`). Binary `elmficA14`. These cases were met while
writing the programs; each was removed from the program (or reduced) so that the programs compare cleanly. Listed so nobody
reports them again.

Decided differences (Ficcus differs from Elm on purpose):
- `Json.Decode.decodeString` on truncated input: Elm (node 21) says `Unexpected end of JSON input`, the C kernel says `Syntax error` (K-error-text; the V8 text varies by version). Program 05.
- Regex match `index` and string offsets count code points (L22/L11), Elm counts UTF-16 units: `Regex.find (rx "b") "ééb😀b"` gives `[2,4]` against `[2,5]`. Program 11.
- 64 bit Int against JS numbers: `7 * (1 + x + x^2 + x^3)` above 2^53 (program 04); `//` and `truncate` are exact beyond 2^31 (L0, programs 19: `truncate 1.0e10` is 1410065408 in Elm, `600851475143 // d` is wrong in Elm).
- `logBase 10 1000` is `3` (L5), Elm gives `2.9999999999999996`. Program 19.

Elm 0.19.3 bugs met (the oracle itself is wrong or crashes; the Ficcus C output is right):
- JS self tail call loop reassigns its parameters while a closure created in the loop body captures them:
  `cpsFib n k = if n < 2 then k n else cpsFib (n - 1) (\a -> cpsFib (n - 2) (\b -> k (a + b)))` overflows the stack in node, the C build prints 55 for `cpsFib 10 identity` (checked). Program 14 uses a two function form.
- Mutual tail calls are not eliminated in JS (`isEven 100000` overflows the node stack); the programs use depths up to 3000. The C build was not tried at depth here.
- `Regex.split (Regex.fromString "" ...)` (an empty match) makes node throw `Invalid array length`. Removed from program 11.
- `modBy 0` throws in Elm (L1 decides 0 in Ficcus). Removed from program 19.

Mode limits (not bugs): a no-RC build never frees and copies a vector on every `set`/`push`, so a large program exhausts the 3 GB cap in the plain and
DROP_ALL modes (tic-tac-toe over the whole game tree, a 200000 element sieve): sizes were reduced, and program 30 (large vectors) runs only counted (`modes` file).
