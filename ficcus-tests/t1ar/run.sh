#!/bin/bash
# T1a review scratch runner (docs/T1A-REVIEW.md): each case of src/ compiled --rc (gcc -O2, and ASan+UBSan without the pool) and to
# JavaScript (node, effects2/ref/run.js); prints the C output, the FIC_STATS lines, the sanitizer verdict and C = JS.
#   ficcus-tests/t1ar/run.sh ELM ELM_HOME [Case ...]
set -u
ELM=$(realpath "$1"); H=$(realpath "$2"); shift 2
HERE=$(cd "$(dirname "$0")" && pwd); RT=$HERE/../../../targets/c; RUNJS=$HERE/../effects2/ref/run.js
T=$(mktemp -d "${CLAUDE_CODE_TMPDIR:-/tmp}/t1ar.XXXX"); cp -r "$HERE/elm.json" "$HERE/src" "$T/"
export FIC_TIME=1700000000000 TZ=UTC
TIE_EXPECTED="R3TieBreak"   # F2: equal virtual deadlines, so C = JS is not expected there
cases=("$@"); [ ${#cases[@]} -eq 0 ] && cases=($(cd "$HERE/src" && ls *.fic | sed 's/\.fic$//'))
for n in "${cases[@]}"; do
  echo "=== $n"
  (cd "$T" && ELM_HOME=$H "$ELM" make "src/$n.fic" --output="$T/$n.c" --rc >/dev/null 2>"$T/$n.err") || { cat "$T/$n.err" | tail -5; continue; }
  grep -q '#error "internal: Concurrent' "$T/$n.c" && echo "C has #error"
  gcc -std=c99 -ffp-contract=off -w -O2 -DFIC_STATS -I "$RT" "$T/$n.c" -o "$T/$n.o2" -lm || continue
  gcc -std=c99 -ffp-contract=off -w -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=undefined -DFIC_NO_POOL -DFIC_STATS \
      -I "$RT" "$T/$n.c" -o "$T/$n.san" -lm || continue
  timeout 120 "$T/$n.o2" >"$T/$n.c.out" 2>"$T/$n.c.err"; echo "C exit $?"; cat "$T/$n.c.out"; grep FIC_STATS "$T/$n.c.err"
  grep -v FIC_STATS "$T/$n.c.err" | head -3
  timeout 300 "$T/$n.san" >"$T/$n.s.out" 2>"$T/$n.s.err"; e=$?
  cmp -s "$T/$n.c.out" "$T/$n.s.out" && grep -q "live 0" "$T/$n.s.err" && ! grep -q "Sanitizer\|runtime error" "$T/$n.s.err" \
    && echo "san: same output, live 0, clean (exit $e)" || { echo "san: DIFFERS (exit $e)"; grep -m3 "Sanitizer\|runtime error\|live" "$T/$n.s.err"; }
  if (cd "$T" && ELM_HOME=$H "$ELM" make "src/$n.fic" --output="$T/$n.js" >/dev/null 2>"$T/$n.jerr"); then
    timeout 120 node "$RUNJS" "$T/$n.js" "$n" >"$T/$n.js.out" 2>"$T/$n.js.err"; echo "JS exit $?"
    if grep -q FIC_JS_TIE "$T/$n.js.err"; then              # F2: run.js flags timers due at the same virtual time
      case " $TIE_EXPECTED " in *" $n "*) echo "JS timer tie flagged (expected)";; *) echo "JS timer tie flagged (UNEXPECTED)";; esac
    else case " $TIE_EXPECTED " in *" $n "*) echo "JS timer tie NOT flagged (expected one)";; esac; fi
    cmp -s "$T/$n.c.out" "$T/$n.js.out" && echo "C = JS" || { echo "C != JS; JS output:"; cat "$T/$n.js.out"; head -3 "$T/$n.js.err"; }
  else echo "JS compile failed"; tail -3 "$T/$n.jerr"; fi
done
echo "work dir $T"
