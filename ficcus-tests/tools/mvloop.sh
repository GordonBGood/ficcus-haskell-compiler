#!/bin/bash
# mvloop.sh OUT N NET "RTS" BIN1 [BIN2 ...] : N rounds; each round compiles the known15 mutant 216 once with each binary
# (interleaved), with the RTS options "RTS" (may be empty) and NET = online | offline (unshare -rn: no network).
# A run counts as a crash when the output has no "rc check:"; its output and eventlog are kept in OUT/crash-*.
# OUT/summary.txt gets one line per binary. A binary is a name in $FICCUS_BIN (default: the workspace's bin/, next to
# the compiler tree) or a path. OUT must be an absolute path.
set -u
out=$1; n=$2; net=$3; rts=$4; shift 4
tree=$(cd "$(dirname "$0")/../.." && pwd)
B=${FICCUS_BIN:-$tree/../bin}
work=$out/known15; mkdir -p $out; rm -rf $work
cp -r $tree/ficcus-tests/known15 $work; rm -rf $work/elm-stuff
home=$out/home; mkdir -p $home
start=$PWD
bin() { case $1 in /*) echo "$1";; */*) echo "$start/$1";; *) echo "$B/$1";; esac; }
declare -A bad; for b in "$@"; do bad[$b]=0; done
pre=""; [ "$net" = offline ] && pre="unshare -rn"
cd $work
ELM_HOME=$home FICCUS_RC_MUTATE=216 $(bin $1) make src/Known15.fic --output=x.c --rc >/dev/null 2>&1   # online warm-up: registry and packages
for i in $(seq 1 $n); do
  for b in "$@"; do
    ev=$out/cur.eventlog
    o=$($pre env ELM_HOME=$home FICCUS_RC_MUTATE=216 timeout 120 $(bin $b) make src/Known15.fic --output=x.c --rc +RTS $rts -l -ol$ev -RTS 2>&1)
    if ! grep -q "rc check:" <<<"$o"; then
      bad[$b]=$((bad[$b]+1)); k=$out/crash-$(basename $b)-$i; echo "$o" > $k.txt; mv $ev $k.eventlog
      echo "$(date +%T) round $i $b: $(grep -o 'blocked indefinitely[a-zA-Z ]*\|resource busy[^)]*' <<<"$o" | head -1)" >> $out/log.txt
    fi
  done
  [ $((i % 250)) = 0 ] && echo "$(date +%T) round $i: $(for b in "$@"; do echo -n "$b ${bad[$b]} "; done)" >> $out/log.txt
done
for b in "$@"; do echo "$b net=$net rts='$rts' crashes ${bad[$b]} of $n" | tee -a $out/summary.txt; done
