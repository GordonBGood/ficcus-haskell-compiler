#!/bin/bash
# The serial regression gates of the compiler session (STAGE4-FIX1.md section 7). BIN=elmficNN [S=scratch dir] ficcus-tests/gates.sh; takes about one hour.
# Expected: runtime 0 non-ok lines; attach 63 cases 0 differ; types 267 PASS 1 XFAIL (one case may flake under load: rerun); JS identity 26; examples 264 ok x3;
# fbip 0 failures; faults 0 missed; suite PASS; typed 568/12/1; library no REGRESSION; elmdiff 1160 SAME + 15 apps.
W=$(cd "$(dirname "$0")/../.." && pwd); R=$W/ficcus-haskell-compiler
S=${S:-$(mktemp -d)}
B=$W/bin/${BIN:-elmfic80}; G=$S/gates; mkdir -p $G; cd $W
fresh() { rm -rf $S/h_$1; mkdir -p $S/h_$1; cp -r $W/elm-home-difftest/0.19.3 $S/h_$1/; echo $S/h_$1; }
step() { echo "=== $1 $(date +%T)"; }
step runtime;  (cd $R && TMPDIR=$(mktemp -d) sh runtime/test.sh 2>&1 | grep -vc "^ok" ; ) > $G/runtime.txt 2>&1; cat $G/runtime.txt
step attach;   python3 tests/attach/attach.py --elm $B --rc > $G/attach.txt 2>&1; tail -1 $G/attach.txt
step types;    (cd tests/types && python3 typetests.py --elm $B --compare results/baseline.json > $G/types.txt 2>&1); tail -4 $G/types.txt
step jsid;     $R/ficcus-tests/jsid.sh $W/bin/elm0193 $B $S/jh $S/jw > $G/jsid.txt 2>&1; tail -2 $G/jsid.txt
H=$(fresh ex); 
step examples; (cd $R && python3 ficcus-tests/examples.py --elm $B --safe $W/tools/safe --elm-home $H > $G/ex1.txt 2>&1); grep -c "^ok" $G/ex1.txt; grep -E "FAIL" $G/ex1.txt | head
step ex-dropall; (cd $R && FIC_DROP_ALL=1 python3 ficcus-tests/examples.py --elm $B --safe $W/tools/safe --elm-home $H > $G/ex2.txt 2>&1); grep -c "^ok" $G/ex2.txt; grep -E "FAIL" $G/ex2.txt | head
step ex-rcsan; (cd $R && FIC_RC=1 FIC_SAN=1 python3 ficcus-tests/examples.py --elm $B --safe $W/tools/safe --elm-home $H > $G/ex3.txt 2>&1); grep -c "^ok" $G/ex3.txt; grep -E "FAIL" $G/ex3.txt | head
step fbip;     python3 $R/ficcus-tests/fbip_check.py --elm $B --elm-home $H --safe $W/tools/safe > $G/fbip.txt 2>&1; tail -2 $G/fbip.txt
step rcfaults; python3 $R/ficcus-tests/rccheck_faults.py --elm $B --elm-home $H > $G/faults.txt 2>&1; tail -2 $G/faults.txt
step rcfaults-big; python3 $R/ficcus-tests/rccheck_faults.py --elm $B --elm-home $H --only vec,fbip,reuse,evo,parse --sample 0.02 --seed 1 > $G/faults2.txt 2>&1; tail -2 $G/faults2.txt
step rcgate-san; python3 $R/ficcus-tests/rc_gate.py --elm $B --elm-home $H --san > $G/rcgate.txt 2>&1; tail -3 $G/rcgate.txt
step suite;    python3 targets/run_all.py --san > $G/suite.txt 2>&1; tail -4 $G/suite.txt
step typed;    python3 $R/ficcus-tests/typed_check.py --elm $B --safe $W/tools/safe --elm-home $(fresh tc) --out $S/tcout --jobs 2 corpus/pkgs-sample corpus/apps > $G/typed.txt 2>&1; tail -3 $G/typed.txt
step lib-rcsan; $R/ficcus-tests/libsuite.sh rcsan $B $(fresh lib) $S/libw --compare results/baseline.json > $G/lib.txt 2>&1; tail -4 $G/lib.txt
step elmdiff;  python3 elmdiff/elmdiff.py --a ./bin/elm0193 --b $B --pkgs corpus/pkgs-sample --apps corpus/apps --out $S/elmdiff80 --elm-home $(fresh ed) --timeout 120 > $G/elmdiff.txt 2>&1; tail -4 $G/elmdiff.txt
echo "=== DONE $(date +%T)"
