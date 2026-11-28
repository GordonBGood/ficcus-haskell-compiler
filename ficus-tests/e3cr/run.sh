#!/bin/sh
# E3c review (docs/E3C-REVIEW.md): the reproducers, one item at a time.  Usage:
#   ELM_HOME=H OUT=/some/scratch sh ficus-tests/e3cr/run.sh [1|2|3|4|5|6|7]   (ELM: default bin/elmficE3d2; REF: bin/elmficT1c)
# Item 4 shows M1 before the fix (now: every compile refused); item 7 is the M1 test (shadow.sh).
# One heavy job at a time; item 5 needs about 1 GB of memory, item 6 compiles 100 programs.
set -u
D=$(cd "$(dirname "$0")" && pwd); T=$D/..; RT=$T/../runtime; BIN=$T/../../bin
ELM=${ELM:-$BIN/elmficE3d2}; REF=${REF:-$BIN/elmficT1c}; OUT=${OUT:?set OUT to a scratch directory}
export ELM
stats() { sed -e '/FIC_STATS model/d' -e 's/FIC_STATS: allocs [0-9]* \(live [0-9]*\).*/\1/' -e '/^    #[1-9]/d'; }
item() { [ $# -eq 0 ] || [ "$SEL" = all ] || [ "$SEL" = "$1" ]; }
SEL=${1:-all}; mkdir -p "$OUT"

if item 1; then echo "== 1 lifetime of raw vectors (host/host_life.c)"
  "$D/build.sh" E3crLife "$D/host/host_life.c" "$OUT"
  for c in retain_in retain_out twice echo list narrow_out borrow_kept write_after read_after_drop read_after_send8; do
    FIC_LIFE=$c "$OUT/E3crLife-host_life" 2>&1 | stats | grep -E '^case|want|retained|program|ERROR|^READ|live|borrowed|host'; done
  gcc -std=c99 -ffp-contract=off -w -O2 -DFIC_RC -I "$RT" "$OUT/E3crLife.c" "$D/host/host_life.c" -DFIC_HOST_MAIN=life_main -o "$OUT/life-pool" -lm
  FIC_LIFE=reuse "$OUT/life-pool" | grep handed
fi

if item 2; then echo "== 2 range checks at the edges (edges.py, a JavaScript model of elm/json's int rule, the ranges, Math.fround)"
  "$D/build.sh" E3cSized "$T/effects3/host/host3.c" "$OUT" && python3 "$D/edges.py" "$OUT/E3cSized-host3" | grep -E '^sends|DIFF|COUNT|SANIT|^edges'
fi

if item 3; then echo "== 3 JUINT and raw nodes in a Json.Value payload: API path = text path = Elm twin"
  "$D/build.sh" E3crLife "$T/effects3/host/host3.c" "$OUT" && "$D/build.sh" E3crLife "$T/effects3c/host/host_api.c" "$OUT"
  mkdir -p "$OUT/tw/src" && cp "$D/elm.json" "$OUT/tw/"
  python3 -c "import sys; sys.path.insert(0, '$T'); import effects_e3c as e; open('$OUT/tw/src/E3crLife.elm', 'w').write(e.twin(open('$D/src/E3crLife.fic').read()))"
  (cd "$OUT/tw" && "$BIN/elm0193" make src/E3crLife.elm --output="$OUT/tw/life.js" >/dev/null)
  FIC_HOST_SCRIPT=$D/scripts/json_twin.script node "$T/effects3/ref/run3.js" "$OUT/tw/life.js" E3crLife > "$OUT/j_elm.txt" 2>&1
  FIC_HOST_SCRIPT=$D/scripts/json_twin.script "$OUT/E3crLife-host3" > "$OUT/j_fic.txt" 2> "$OUT/j_fic.err"
  echo "text path vs Elm (expected: only 9007199254740993 and the lone surrogates, both decided earlier):"; diff "$OUT/j_elm.txt" "$OUT/j_fic.txt"
  FIC_HOST_SCRIPT=$D/scripts/json_api.script "$OUT/E3crLife-host_api" > "$OUT/ja.txt" 2> "$OUT/ja.err"; grep -o 'live [0-9]*' "$OUT/ja.err"
  python3 - "$OUT" <<'EOF'
import json, sys
o = sys.argv[1]; prog = []
for l in open(o + "/ja.txt").read().split("\n"):
    if l.startswith("output: "): prog.append(json.loads(l[8:]))
    elif l.startswith("jsonOut: "): prog.append(l)
t = [l for l in open(o + "/j_elm.txt").read().split("\n") if l][:len(prog)]
bad = [(x, y) for x, y in zip(prog, t) if x != y]
print(len(prog), "API lines vs Elm twin:", "all equal" if not bad and len(t) == len(prog) else bad)
EOF
fi

if item 4; then echo "== 4 a project module Int8 or Vector instead of the overlay (shadow/a b c)"
  for d in a b c; do
    rm -rf "$OUT/sh_$d"; cp -r "$D/shadow/$d" "$OUT/sh_$d"
    (cd "$OUT/sh_$d" && "$ELM" make src/Main.fic --output="$OUT/sh_$d/Main.c" --rc >/dev/null 2>&1; echo "$d: compiler exit $?")
    sc=$D/scripts/shadow_i8.script; [ $d = c ] && sc=$D/scripts/shadow_vec.script
    gcc -std=c99 -w -O2 -DFIC_RC -I "$RT" -I "$OUT/sh_$d" "$OUT/sh_$d/Main.c" "$T/effects3/host/host3.c" -DFIC_HOST_MAIN=fic_test_host_main \
      -o "$OUT/sh_$d/gcc" -lm 2>&1 | grep -m1 error && echo "$d: gcc refuses the C"
    [ -x "$OUT/sh_$d/gcc" ] && { FIC_HOST_SCRIPT=$sc "$OUT/sh_$d/gcc" >/dev/null 2>&1; echo "$d: gcc -O2 run exit $?"; }
    tcc -std=c99 -DFIC_RC -I "$RT" -I "$OUT/sh_$d" "$OUT/sh_$d/Main.c" "$T/effects3/host/host3.c" -DFIC_HOST_MAIN=fic_test_host_main \
      -o "$OUT/sh_$d/tcc" -lm -lpthread >/dev/null 2>&1 && { FIC_HOST_SCRIPT=$sc "$OUT/sh_$d/tcc" >/dev/null 2>&1; echo "$d: tcc run exit $?"; }
  done
fi

if item 5; then echo "== 5 parser and writer: depth 1e6, big strings, long numbers, bad text (FIC_STACK_MB=1, ulimit -s 256, ASan)"
  "$D/build.sh" E3cDeep "$D/host/host_stress.c" "$OUT/s" -DFIC_STACK_MB=1 && "$D/build.sh" E3crLife "$D/host/host_stress.c" "$OUT/s" -DFIC_STACK_MB=1
  for c in deep big; do (ulimit -s 256; FIC_STRESS=$c "$OUT/s/E3cDeep-host_stress" 2>&1 | stats | cut -c1-160 | grep -v '^$'); done
  FIC_STRESS=text "$OUT/s/E3crLife-host_stress" 2>&1 | stats | grep -E '^text|json \\"|json [[{]|ERROR|live' | cut -c1-140
fi

if item 6; then echo "== 6 identity of the C text against $REF (only port programs may differ)"
  python3 "$T/a3b_identity.py" --elm "$ELM" --ref "$REF" --elm-home "$ELM_HOME" --more | grep -v '^identical'
fi

if item 7; then echo "== 7 M1 fixed: project modules Int8 / Vector / both (shadow.sh)"
  OUT=$OUT/shadow sh "$D/shadow.sh"
fi
