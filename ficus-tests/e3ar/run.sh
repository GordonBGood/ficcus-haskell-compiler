#!/bin/sh
# E3a review reproducers (docs/E3A-REVIEW.md). Usage: ficus-tests/e3ar/run.sh <elmfic binary> <elm-home> <scratch dir>
# Needs bin/elm0193 and node for the Elm twin (R2Text). Each step prints what it checks; read the output against the report.
set -u
B=$(realpath "$1"); EH=$(realpath "$2"); S=$(realpath "$3"); D=$(cd "$(dirname "$0")" && pwd)
RT=$D/../../../targets/c; RUNTIME=$D/../../runtime; E=$D/../../../bin/elm0193
SAN="-fsanitize=address,undefined -fno-sanitize-recover=undefined -g -DFIC_NO_POOL"
mkdir -p "$S/ep/src"; cp "$D/elm.json" "$S/ep/"
cd "$D"
fic() { ELM_HOME=$EH "$B" make "src/$1.fic" --output="$S/$1$2.c" "$2" >"$S/$1$2.log" 2>&1 || echo "$1 $2: make failed"; }
cc_() { gcc -std=c99 -ffp-contract=off -w "$@" -lm; }
echo "== F1: List String on a port / as flags does not compile (fic_o_pp undeclared)"
for p in R3PortList R3FlagsList; do fic $p --rc; cc_ -O1 -DFIC_RC -I "$RT" "$S/$p--rc.c" -o "$S/$p" 2>&1 | grep -m1 error; done
echo "== ownership and re-entrancy (own.c, --rc, ASan+UBSan): want no report, live 0"
fic R1Own --rc; cc_ $SAN -DFIC_STATS -DFIC_RC -I "$RT" -I "$S" -I "$RUNTIME" "$S/R1Own--rc.c" host/own.c -DFIC_HOST_MAIN=own_main -o "$S/own"
"$S/own" 2>&1 | tail -3
echo "== decoder texts against Elm (drive.c vs ref/drive.js): differences are L11, L21 and the JS 'in' corners (F4)"
python3 mklines.py > "$S/lines.txt"
cp src/R2Text.fic "$S/ep/src/R2Text.elm"; (cd "$S/ep" && ELM_HOME=$EH "$E" make src/R2Text.elm --output="$S/R2Text.js" >/dev/null)
node ref/drive.js "$S/R2Text.js" "$S/lines.txt" > "$S/r2.elm"
fic R2Text --rc; cc_ $SAN -DFIC_STATS -DFIC_RC -I "$RT" -I "$RUNTIME" "$S/R2Text--rc.c" host/drive.c -DFIC_HOST_MAIN=drive_main -o "$S/drive"
FIC_SCRIPT=$S/lines.txt "$S/drive" > "$S/r2.fic" 2>"$S/r2.err"; grep live "$S/r2.err"
diff "$S/r2.elm" "$S/r2.fic" | grep -c '^[<>]'; grep -c internal "$S/r2.fic"
echo "== F2: deep values (deep.c, -O2): to_json exits; a refused 10000 deep value gives a 400 MB text"
cc_ -O2 -DFIC_STATS -DFIC_RC -I "$RT" -I "$RUNTIME" "$S/R2Text--rc.c" host/deep.c -DFIC_HOST_MAIN=deep_main -o "$S/deep"
DEEP_MODE=tojson DEEP=1000001 "$S/deep" 2>&1 | grep -v FIC_STATS; DEEP_MODE=refuse DEEP=10000 /usr/bin/time -f "%es %MkB" "$S/deep" 2>&1 | grep -v FIC_STATS
echo "== F3: flags (flags.c): a failed start cannot be retried; partial work freed"
fic R1Flags --rc; cc_ $SAN -DFIC_STATS -DFIC_RC -I "$RT" -I "$RUNTIME" "$S/R1Flags--rc.c" host/flags.c -DFIC_HOST_MAIN=flags_main -o "$S/flags"
for m in retry failret unsealed; do FLAGS_MODE=$m "$S/flags" 2>&1 | grep -E 'start|live'; done
echo "== F5: a program without ports gets the ports runtime and the #undef from a string literal"
fic R4NoPorts --rc; grep -c 'undef FIC_TAG_JNULL' "$S/R4NoPorts--rc.c"
