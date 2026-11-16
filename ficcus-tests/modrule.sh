#!/bin/bash
# modrule.sh NEWELM OLDELM ELM_HOME WORK : the module rule of V2 (a module of the core library that Ficcus adds yields to a module of
# the project or of a package of the same name). Each project of modrule/ is built to C (rc) with NEWELM, built with gcc, run, and the
# Debug.log line compared with expected. With OLDELM (a binary without the rule, or "-") the local and package projects must fail there
# with the ambiguous module error. The .elm projects are also built to JS with NEWELM and with bin/elm0193: the JS must be identical.
R=$(cd "$(dirname "$0")/../.." && pwd); H="$(dirname "$0")"
NEW=$(realpath "$1"); OLD=$2; [ "$OLD" != "-" ] && OLD=$(realpath "$OLD"); EH=$(realpath "$3"); W=$(realpath -m "$4")
mkdir -p "$W"; fail=0
expect() { # project main expected-line old-fails
  local p=$1 main=$2 want=$3 oldfails=$4 d=$W/$1
  rm -rf "$d"; cp -r "$H/modrule/$p" "$d"
  if ! (cd "$d" && ELM_HOME=$EH "$R/tools/safe" "$NEW" make src/$main --output=x.c --rc >new.log 2>&1); then echo "FAIL $p: compile:"; head -20 "$d/new.log"; fail=1; return; fi
  gcc -O1 -DFIC_RC -DFIC_STATS -o "$d/x" "$d/x.c" -lm 2>"$d/cc.log" || { echo "FAIL $p: gcc"; head "$d/cc.log"; fail=1; return; }
  got=$("$d/x" 2>&1 | grep -v '^FIC_STATS' | head -3)
  if [ "$got" = "$want" ]; then echo "ok   $p ($main): $got"; else echo "FAIL $p: got '$got' want '$want'"; fail=1; fi
  if [ "$OLD" != "-" ] && [ "$oldfails" = 1 ]; then
    if (cd "$d" && ELM_HOME=$EH "$R/tools/safe" "$OLD" make src/$main --output=y.c --rc >old.log 2>&1); then echo "FAIL $p: the old compiler built it"; fail=1
    elif grep -qi "ambiguous\|AMBIGUOUS" "$d/old.log"; then echo "ok   $p: the old compiler reports the ambiguous module"; else echo "FAIL $p: old compiler failed for another reason"; head -5 "$d/old.log"; fail=1; fi
  fi
}
expect local_elm Main.elm 'local Vector: (4,10)' 1
expect local_fic Main.fic 'local Vector: (4,10)' 1
expect pkg Main.fic 'package Vector: 3' 1
expect core Main.fic 'core Vector: (4,[1,20,3,4])' 0
expect core_elm Main.elm 'core Vector: (4,[1,20,3,4])' 0
# JS identity for the Elm project with its own Vector (no overlay directory in a JS build, but the rule must not move anything)
for p in local_elm; do
  d=$W/js_$p; rm -rf "$d"; cp -r "$H/modrule/$p" "$d"
  (cd "$d" && ELM_HOME=$EH "$R/tools/safe" "$NEW" make src/Main.elm --output=new.js >n.log 2>&1; ELM_HOME=$EH "$R/tools/safe" "$R/bin/elm0193" make src/Main.elm --output=ref.js >r.log 2>&1)
  if cmp -s "$d/new.js" "$d/ref.js"; then echo "ok   $p: JS identical to elm0193"; else echo "FAIL $p: JS differs"; fail=1; fi
done
exit $fail
