#!/bin/bash
# The serial regression gates of the compiler session (STAGE4-FIX1.md section 7). BIN=elmficNN [S=scratch dir] ficcus-tests/gates.sh; takes about one hour (FIX2: step list unchanged, plus stringdiff).
# Expected: runtime 0 non-ok lines; attach 159 cases 0 differ; types 267 PASS 1 XFAIL (one case may flake under load: rerun); JS identity 28; examples 288 ok x3;
# fbip 0 failures; faults 0 missed; suite PASS; typed 568/12/1; library no REGRESSION; elmdiff 1160 SAME + 15 apps.
W=$(cd "$(dirname "$0")/../.." && pwd); R=${R:-$(cd "$(dirname "$0")/.." && pwd)}      # A3: the worktree this script is in (it was the main checkout)
# Disk: every private ELM_HOME is a reflink copy where the file system has them (btrfs: no space used until a file is rewritten; a
# hard link would be unsafe, elm rewrites artifacts.dat in place), and everything the run made under $S is removed when it ends, also
# on an interrupt or a failure (trap). KEEP=1 keeps it (for a look at a failing step). A scratch directory given in S is emptied of
# what the run made, not removed.
KEEP=${KEEP:-}
if [ -z "$S" ]; then S=$(mktemp -d "${CLAUDE_CODE_TMPDIR:-${TMPDIR:-/tmp}}/gates.XXXXXX"); OWN=1; fi
B=$W/bin/${BIN:-elmficN1}; G=$S/gates; mkdir -p $G; cd $W
cleanup() {
  if [ -n "$KEEP" ]; then echo "KEEP=1: $S kept ($(du -sh $S | cut -f1))"; return; fi
  rm -rf "$S"/h_* "$S"/gates "$S"/tcout "$S"/elmdiff80 "$S"/jh "$S"/jw "$S"/libw "$S"/rt_*
  [ -n "$OWN" ] && rmdir "$S" 2>/dev/null
  echo "cleaned: $S"
}
trap cleanup EXIT
trap 'exit 143' TERM INT
fresh() { rm -rf $S/h_$1; mkdir -p $S/h_$1; cp -r --reflink=auto $W/elm-home-difftest/0.19.3 $S/h_$1/; echo $S/h_$1; }
step() { echo "=== $1 $(date +%T)"; }
step runtime;  mkdir -p $S/rt_tmp; (cd $R && TMPDIR=$S/rt_tmp sh runtime/test.sh 2>&1 | grep -vc "^ok" ; ) > $G/runtime.txt 2>&1; cat $G/runtime.txt
step attach;   python3 $R/ficcus-tests/attach/attach.py --elm $B --rc > $G/attach.txt 2>&1; tail -1 $G/attach.txt
step sized-fuzz; python3 $R/ficcus-tests/sized/fuzz.py --elm $B --seeds 40 --first 1000 -j 2 > $G/sizedfuzz.txt 2>&1; tail -1 $G/sizedfuzz.txt     # SIZED: 40 seeds of the 200 (expected: 40 seeds, 0 differ)
step stringdiff; TMPDIR=$S python3 $R/ficcus-tests/stringdiff.py --elm $B --safe $W/tools/safe --elm-home $(fresh sd) --seeds 6 --cases 300 --san > $G/stringdiff.txt 2>&1; tail -1 $G/stringdiff.txt
step types;    (cd tests/types && python3 typetests.py --elm $B --compare results/baseline.json > $G/types.txt 2>&1); tail -4 $G/types.txt
step jsid;     $R/ficcus-tests/jsid.sh $W/bin/elm0193 $B $S/jh $S/jw > $G/jsid.txt 2>&1; tail -2 $G/jsid.txt
H=$(fresh ex); 
step examples; (cd $R && python3 ficcus-tests/examples.py --elm $B --safe $W/tools/safe --elm-home $H > $G/ex1.txt 2>&1); grep -c "^ok" $G/ex1.txt; grep -E "FAIL" $G/ex1.txt | head
step ex-dropall; (cd $R && FIC_DROP_ALL=1 python3 ficcus-tests/examples.py --elm $B --safe $W/tools/safe --elm-home $H > $G/ex2.txt 2>&1); grep -c "^ok" $G/ex2.txt; grep -E "FAIL" $G/ex2.txt | head
step ex-rcsan; (cd $R && FICTEST_RC=1 FICTEST_SAN=1 python3 ficcus-tests/examples.py --elm $B --safe $W/tools/safe --elm-home $H > $G/ex3.txt 2>&1); grep -c "^ok" $G/ex3.txt; grep -E "FAIL" $G/ex3.txt | head
step fbip;     python3 $R/ficcus-tests/fbip_check.py --elm $B --elm-home $H --safe $W/tools/safe > $G/fbip.txt 2>&1; tail -2 $G/fbip.txt
step rcfaults; python3 $R/ficcus-tests/rccheck_faults.py --elm $B --elm-home $H > $G/faults.txt 2>&1; tail -2 $G/faults.txt
step rcfaults-big; python3 $R/ficcus-tests/rccheck_faults.py --elm $B --elm-home $H --only vec,fbip,reuse,evo,parse --sample 0.02 --seed 1 > $G/faults2.txt 2>&1; tail -2 $G/faults2.txt
step rcgate-san; python3 $R/ficcus-tests/rc_gate.py --elm $B --elm-home $H --san > $G/rcgate.txt 2>&1; tail -3 $G/rcgate.txt
step suite;    python3 targets/run_all.py --san > $G/suite.txt 2>&1; tail -4 $G/suite.txt
step typed;    python3 $R/ficcus-tests/typed_check.py --elm $B --safe $W/tools/safe --elm-home $(fresh tc) --out $S/tcout --jobs 2 corpus/pkgs-sample corpus/apps > $G/typed.txt 2>&1; tail -3 $G/typed.txt
step lib-rcsan; $R/ficcus-tests/libsuite.sh rcsan $B $(fresh lib) $S/libw --compare results/baseline.json > $G/lib.txt 2>&1; tail -4 $G/lib.txt
step elmdiff;  python3 elmdiff/elmdiff.py --a ./bin/elm0193 --b $B --pkgs corpus/pkgs-sample --apps corpus/apps --out $S/elmdiff80 --elm-home $(fresh ed) --timeout 120 > $G/elmdiff.txt 2>&1; tail -4 $G/elmdiff.txt
# G53: the summary (the totals the steps above only show as the tail of their files)
step summary
awk -F'|' '/^\| [A-Z_]+ \| [0-9]+ \|$/{ if ($2 == " SAME ") s+=$3; else d+=$3 } END{printf "elmdiff: %d SAME, %d DIFF (packages and apps)\n", s, d}' $G/elmdiff.txt
awk '/^test /{t=1; next} t && NF==0{t=0} t{n++; if ($NF=="PASS") p++} END{printf "suite: %d PASS of %d programs, %d not PASS\n", p, n, n-p}' $G/suite.txt
echo "=== DONE $(date +%T)"
