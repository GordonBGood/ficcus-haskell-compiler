#!/bin/bash
# The serial regression gates of the compiler session (STAGE4-FIX1.md section 7). BIN=elmficNN [S=scratch dir] ficus-tests/gates.sh; takes about one hour (FIX2: step list unchanged, plus stringdiff).
# Expected: runtime 0 non-ok lines; attach 395 cases 0 differ (159 + 37 G70 + 56 G71 + 15 A3b + 18 A5a + 22 A5b + 15 A5f + 18 A5c + 23 A4b + 15 A4bf + 17 A4c); derive 57 cases 0 differ; p1 13 cases 0 failed; types 267 PASS 1 XFAIL (one case may flake under load: rerun); JS identity 28; examples 298 ok x3 (296 + runtime test_sched gcc and clang); e2review gates all ok (the three modes must agree: a lower ex-rcsan count means FAIL lines);
# fbip 0 failures; effects-e2 all ok; effects-e3 all ok (E3a: 124 checks; E3af: 168, 42 cases); e1review all ok; effects-e1 all ok; e1p all ok (E1p); e1pr all ok (2 target rows: E1pR14LambdaSet); e1p-identity all ok; a3b-identity 100 compiles 0 differ (against elmficA5c since A4b; E3a: 4 differ, E2Ports and E2PortsIn in both modes: programs with ports get runtime/fic_ports.h; e1p-identity reports the same two); faults 0 missed; suite PASS; typed 568/12/1; library no REGRESSION; elmdiff 1160 SAME + 15 apps.
W=$(cd "$(dirname "$0")/../.." && pwd); R=${R:-$(cd "$(dirname "$0")/.." && pwd)}      # A3: the worktree this script is in (it was the main checkout)
# Disk: every private ELM_HOME is a reflink copy where the file system has them (btrfs: no space used until a file is rewritten; a
# hard link would be unsafe, elm rewrites artifacts.dat in place), and everything the run made under $S is removed when it ends, also
# on an interrupt or a failure (trap). KEEP=1 keeps it (for a look at a failing step). A scratch directory given in S is emptied of
# what the run made, not removed.
KEEP=${KEEP:-}
# (P1b) one gate run at a time across sessions: the second run waits for the first (the lock is released when this shell exits)
LOCK=${CLAUDE_CODE_TMPDIR:-/tmp}/ficcus-gates.lock; exec 9>"$LOCK"
if ! flock -n 9; then echo "=== waiting for the gate lock $LOCK (another gate run) $(date +%T)"; flock 9; echo "=== gate lock taken $(date +%T)"; fi
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
step attach;   python3 $R/ficus-tests/attach/attach.py --elm $B --rc > $G/attach.txt 2>&1; tail -1 $G/attach.txt
step derive;   python3 $R/ficus-tests/derive/derive.py --elm $B -j 2 > $G/derive.txt 2>&1; tail -1 $G/derive.txt     # A4b: the derive matrix of A4a, with the rows A4b changed (expected: 57 cases, 0 differ; A4c: c-enum-use, c-tostring-use run)
step p1;       python3 $R/ficus-tests/p1/run.py --elm $B > $G/p1.txt 2>&1; tail -1 $G/p1.txt     # P1: extensible-record fields of custom types and derive over them (M2 lifted), Elm twins, --no-rc and --rc ASan+UBSan live 0 (expected: p1: 13 cases, 0 failed)
step sized-fuzz; python3 $R/ficus-tests/sized/fuzz.py --elm $B --seeds 40 --first 1000 -j 2 > $G/sizedfuzz.txt 2>&1; tail -1 $G/sizedfuzz.txt     # SIZED: 40 seeds of the 200 (expected: 40 seeds, 0 differ)
step stringdiff; TMPDIR=$S python3 $R/ficus-tests/stringdiff.py --elm $B --safe $W/tools/safe --elm-home $(fresh sd) --seeds 6 --cases 300 --san > $G/stringdiff.txt 2>&1; tail -1 $G/stringdiff.txt
step types;    (cd tests/types && python3 typetests.py --elm $B --compare results/baseline.json > $G/types.txt 2>&1); tail -4 $G/types.txt
step jsid;     $R/ficus-tests/jsid.sh $W/bin/elm0193 $B $S/jh $S/jw > $G/jsid.txt 2>&1; tail -2 $G/jsid.txt
H=$(fresh ex); 
step examples; (cd $R && python3 ficus-tests/examples.py --elm $B --safe $W/tools/safe --elm-home $H > $G/ex1.txt 2>&1); grep -c "^ok" $G/ex1.txt; grep -E "FAIL" $G/ex1.txt | head
step ex-dropall; (cd $R && FIC_DROP_ALL=1 python3 ficus-tests/examples.py --elm $B --safe $W/tools/safe --elm-home $H > $G/ex2.txt 2>&1); grep -c "^ok" $G/ex2.txt; grep -E "FAIL" $G/ex2.txt | head
step ex-rcsan; (cd $R && FICTEST_RC=1 FICTEST_SAN=1 python3 ficus-tests/examples.py --elm $B --safe $W/tools/safe --elm-home $H > $G/ex3.txt 2>&1); grep -c "^ok" $G/ex3.txt; grep -E "FAIL" $G/ex3.txt | head
step fbip;     python3 $R/ficus-tests/fbip_check.py --elm $B --elm-home $H --safe $W/tools/safe > $G/fbip.txt 2>&1; tail -2 $G/fbip.txt
step effects-e2; python3 $R/ficus-tests/effects_e2.py --elm $B --elm-home $H > $G/effects2.txt 2>&1; tail -1 $G/effects2.txt     # E2 (docs/EFFECTS-CHECK.md steps 4 to 8): scheduler, timers, Random, ports, teardown against Elm 0.19.3 goldens (expected: effects_e2: all ok)
step effects-e3; python3 $R/ficus-tests/effects_e3.py --elm $B --elm-home $H > $G/effects3.txt 2>&1; tail -1 $G/effects3.txt     # E3a/E3b (docs/E3-PORTS-DESIGN.md): host value API, Array payloads, error texts, re-entrancy, flags against Elm 0.19.3 goldens (expected: effects_e3: all ok)
step t1a;      python3 $R/ficus-tests/t1a/run.py --elm $B --ref ${A3B_REF:-$W/bin/elmficA5c} --elm-home $H > $G/t1a.txt 2>&1; tail -1 $G/t1a.txt     # T1a-1 (docs/attach/T1A-NOTES.md): Concurrent on the E2 scheduler, 9 hand-reasoned cases --rc (O2, ASan+UBSan, DROP_ALL; live 0) and --no-rc, the JavaScript reference under node (C = JS), O6, seeded shuffle, C identity of effects3/e2review against A3B_REF (expected: t1a: all ok)
step e1review; python3 $R/ficus-tests/e1_review.py --elm $B --elm-home $H --targets > $G/e1review.txt 2>&1; tail -1 $G/e1review.txt     # E1 review (docs/E1-REVIEW.md): model ownership, R1..R5 with targets (expected: e1_review: all ok)
step effects-e1; python3 $R/ficus-tests/effects_e1.py --elm $B --elm-home $H > $G/effects1.txt 2>&1; tail -1 $G/effects1.txt     # E1 (and E1p switches): G17b, G17bFields, managers, SubsOrder (expected: effects_e1: all ok)
step e1p;      python3 $R/ficus-tests/e1p_measure.py --elm $B --elm-home $H --targets > $G/e1p.txt 2>&1; tail -1 $G/e1p.txt     # E1p (docs/E1P-DESIGN.md): the leaf split, H1..H7 and X programs at their targets (expected: e1p_measure: all ok)
step e1pr;     python3 $R/ficus-tests/e1p_review.py --elm $B --elm-home $H > $G/e1pr.txt 2>&1; tail -1 $G/e1pr.txt     # E1p review (docs/E1P-REVIEW.md): E1pR1, R10, R11, R13 gates; E1pR14LambdaSet a listed target (expected: e1p_review: all ok, 2 target rows)
step e1p-identity; python3 $R/ficus-tests/e1p_identity.py --elm $B --ref $W/bin/elmficG70a --elm-home $H --more > $G/e1pid.txt 2>&1; tail -1 $G/e1pid.txt     # E1p: C text changes only in split or dealiased functions, the 16 suite programs plus e1p, effects, effects2 (expected: e1p_identity: all ok)
step a3b-identity; python3 $R/ficus-tests/a3b_identity.py --elm $B --ref ${A3B_REF:-$W/bin/elmficA5c} --elm-home $H --more > $G/a3bid.txt 2>&1; tail -1 $G/a3bid.txt     # A3b: C text of the suite and the e1p/effects programs byte identical to the reference (A4b: elmficA5c; A3B_REF to change it), --rc and --no-rc (expected: 100 compiles compared, 0 differ)
step e2review; python3 $R/ficus-tests/e2_review.py --elm $B --elm-home $H > $G/e2review.txt 2>&1; tail -1 $G/e2review.txt     # E2 review (docs/E2-REVIEW.md): every program is a gate (the targets became gates with the fixes)
step rcfaults; python3 $R/ficus-tests/rccheck_faults.py --elm $B --elm-home $H > $G/faults.txt 2>&1; tail -2 $G/faults.txt
step rcfaults-big; python3 $R/ficus-tests/rccheck_faults.py --elm $B --elm-home $H --only vec,fbip,reuse,evo,parse --sample 0.02 --seed 1 > $G/faults2.txt 2>&1; tail -2 $G/faults2.txt
step rcgate-san; python3 $R/ficus-tests/rc_gate.py --elm $B --elm-home $H --san > $G/rcgate.txt 2>&1; tail -3 $G/rcgate.txt
step suite;    python3 targets/run_all.py --san > $G/suite.txt 2>&1; tail -4 $G/suite.txt
step typed;    python3 $R/ficus-tests/typed_check.py --elm $B --safe $W/tools/safe --elm-home $(fresh tc) --out $S/tcout --jobs 2 corpus/pkgs-sample corpus/apps > $G/typed.txt 2>&1; tail -3 $G/typed.txt
step lib-rcsan; $R/ficus-tests/libsuite.sh rcsan $B $(fresh lib) $S/libw --compare results/baseline.json > $G/lib.txt 2>&1; tail -4 $G/lib.txt
step elmdiff;  python3 elmdiff/elmdiff.py --a ./bin/elm0193 --b $B --pkgs corpus/pkgs-sample --apps corpus/apps --out $S/elmdiff80 --elm-home $(fresh ed) --timeout 120 > $G/elmdiff.txt 2>&1; tail -4 $G/elmdiff.txt
# G53: the summary (the totals the steps above only show as the tail of their files)
step summary
awk -F'|' '/^\| [A-Z_]+ \| [0-9]+ \|$/{ if ($2 == " SAME ") s+=$3; else d+=$3 } END{printf "elmdiff: %d SAME, %d DIFF (packages and apps)\n", s, d}' $G/elmdiff.txt
awk '/^test /{t=1; next} t && NF==0{t=0} t{n++; if ($NF=="PASS") p++} END{printf "suite: %d PASS of %d programs, %d not PASS\n", p, n, n-p}' $G/suite.txt
echo "=== DONE $(date +%T)"
