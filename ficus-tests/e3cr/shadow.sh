#!/bin/sh
# E3c review M1 (docs/E3C-REVIEW.md on review/e3c): a project module `Int8`, `Vector`, or both, in place of the overlay.
#   ELM_HOME=H OUT=/some/scratch sh ficus-tests/e3cr/shadow.sh        (ELM: default bin/elmficE3d2; REF: bin/elm0193)
# Per case (shadow_i8, shadow_vec, shadow_both):
#   good/  the project modules used inside the program, ports of standard types: compiles, builds with gcc (default errors, so
#          gcc 15 refuses bad C), gcc ASan + UBSan and tcc, and each run prints what Elm prints (node, effects3/ref/run3.js)
#   bad/   a port of the project's own type: refused with Elm's payload error (the same report title as elm0193)
# Last line: "shadow: N ok, M failed".
set -u
D=$(cd "$(dirname "$0")" && pwd); T=$D/..; RT=$T/../runtime; BIN=$T/../../bin
ELM=${ELM:-$BIN/elmficE3d2}; REF=${REF:-$BIN/elm0193}; OUT=${OUT:?set OUT to a scratch directory}
HOST=$T/effects3/host/host3.c; SC=$D/shadow.script
ok=0; bad=0
pass() { echo "ok   $1"; ok=$((ok + 1)); }
fail() { echo "FAIL $1"; bad=$((bad + 1)); }
mkdir -p "$OUT"
for c in shadow_i8 shadow_vec shadow_both; do
  g=$OUT/$c/good; b=$OUT/$c/bad; rm -rf "$OUT/$c"; mkdir -p "$OUT/$c"
  cp -r "$D/$c/good" "$g"; cp -r "$D/$c/bad" "$b"
  # the Elm reference: the same program as .elm
  mkdir -p "$OUT/$c/elm"; cp "$g/elm.json" "$OUT/$c/elm/"; cp -r "$g/src" "$OUT/$c/elm/"; mv "$OUT/$c/elm/src/Main.fic" "$OUT/$c/elm/src/Main.elm"
  (cd "$OUT/$c/elm" && "$REF" make src/Main.elm --output=main.js >/dev/null 2>&1) || { fail "$c: elm0193 refuses the reference"; continue; }
  FIC_HOST_SCRIPT=$SC node "$T/effects3/ref/run3.js" "$OUT/$c/elm/main.js" Main > "$OUT/$c/want.txt" 2>&1
  if (cd "$g" && "$ELM" make src/Main.fic --output="$g/Main.c" --rc > "$g/compile.txt" 2>&1); then pass "$c: compiles"
  else fail "$c: compiler exit $? ($(head -1 "$g/compile.txt"))"; continue; fi
  if gcc -std=c99 -ffp-contract=off -O2 -DFIC_RC -I "$RT" -I "$g" "$g/Main.c" "$HOST" -DFIC_HOST_MAIN=fic_test_host_main \
       -o "$g/gcc" -lm > "$g/gcc.txt" 2>&1; then pass "$c: gcc builds"; else fail "$c: gcc refuses the C"; fi
  if gcc -std=c99 -ffp-contract=off -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -DFIC_RC -I "$RT" -I "$g" \
       "$g/Main.c" "$HOST" -DFIC_HOST_MAIN=fic_test_host_main -o "$g/san" -lm > "$g/san.txt" 2>&1; then :; else fail "$c: san build"; fi
  if tcc -std=c99 -DFIC_RC -I "$RT" -I "$g" "$g/Main.c" "$HOST" -DFIC_HOST_MAIN=fic_test_host_main -o "$g/tcc" -lm -lpthread \
       > "$g/tcc.txt" 2>&1; then pass "$c: tcc builds"; else fail "$c: tcc refuses the C"; fi
  for x in gcc san tcc; do
    [ -x "$g/$x" ] || continue
    FIC_HOST_SCRIPT=$SC "$g/$x" > "$g/run_$x.txt" 2> "$g/err_$x.txt"; e=$?
    if [ $e -eq 0 ] && cmp -s "$OUT/$c/want.txt" "$g/run_$x.txt"; then pass "$c: $x run = Elm"
    else fail "$c: $x run exit $e, output $(cmp -s "$OUT/$c/want.txt" "$g/run_$x.txt" && echo equal || echo differs)"; fi
  done
  # the refused variant: Elm's payload error from both compilers
  mkdir -p "$OUT/$c/belm"; cp "$b/elm.json" "$OUT/$c/belm/"; cp -r "$b/src" "$OUT/$c/belm/"; mv "$OUT/$c/belm/src/Main.fic" "$OUT/$c/belm/src/Main.elm"
  (cd "$OUT/$c/belm" && "$REF" make src/Main.elm --output=/dev/null > err.txt 2>&1); re=$?
  (cd "$b" && "$ELM" make src/Main.fic --output="$b/Main.c" --rc > err.txt 2>&1); fe=$?
  wt=$(grep -o -m1 -- '-- [A-Z][A-Z ]* -' "$OUT/$c/belm/err.txt"); ft=$(grep -o -m1 -- '-- [A-Z][A-Z ]* -' "$b/err.txt")
  if [ $re -ne 0 ] && [ $fe -ne 0 ] && [ -n "$wt" ] && [ "$wt" = "$ft" ]; then pass "$c: port of the project type refused ($ft)"
  else fail "$c: refusal: elm0193 exit $re '$wt', ficus exit $fe '$ft'"; fi
done
echo "shadow: $ok ok, $bad failed"
