#!/bin/sh
# COMPAT-1 / G48: elmdiff over the full corpus, A = official Elm 0.19.3, B = the current Ficus binary.
# Night queue step:  nq/submit.sh compat-elmdiff <this worktree> <commit> run:nq/jobs-extra/compat-elmdiff.sh
# nq runs it as `sh FILE` from the worktree; the workspace root is the worktree's parent directory.
# Modes (all that elmdiff has): packages check (make, no files) and docs (--docs); applications dev, debug, optimize.
# B: $COMPAT_B (a name in bin/), else bin/elmficR1, else the last elmficX entry of bin/BUILDS.txt.
# Output: results/compat/<B>/ (results.jsonl, summary.md, diffs) and results/compat/<B>/totals.txt.
# Re-running resumes into the same directory (--resume) and keeps its ELM_HOME copy.
set -eu
WT=$(pwd)
W=$(cd "$WT/.." && pwd)
cd "$W"
[ -f elmdiff/elmdiff.py ] || { echo "compat-elmdiff: no elmdiff/ in $W" >&2; exit 2; }

B=${COMPAT_B:-elmficR1}
if [ ! -x "bin/$B" ]; then
  B=$(sed -n 's/^\(elmfic[A-Za-z0-9]*\):.*/\1/p' bin/BUILDS.txt | tail -1)
fi
[ -n "$B" ] && [ -x "bin/$B" ] || { echo "compat-elmdiff: no binary bin/$B" >&2; exit 2; }
[ -x bin/elm0193 ] || { echo "compat-elmdiff: no bin/elm0193" >&2; exit 2; }

OUT=results/compat/$B
HOME_COPY=$OUT/elm-home
mkdir -p "$OUT"
RESUME=
if [ -f "$OUT/results.jsonl" ]; then
  RESUME=--resume
else
  # fresh package cache from the pre-downloaded corpus home (no network needed for most packages)
  rm -rf "$HOME_COPY"; mkdir -p "$HOME_COPY"
  cp -r --reflink=auto elm-home-difftest/0.19.3 "$HOME_COPY/"
fi

# B reads FICUS_HOME first (R1); make both compilers use the same ELM_HOME that elmdiff sets
unset FICUS_HOME

{
  echo "compat-elmdiff start $(date '+%F %T')"
  echo "A bin/elm0193 ($(./bin/elm0193 --version 2>&1))"
  echo "B bin/$B ($(./bin/$B --version 2>&1)); BUILDS.txt: $(grep "^$B:" bin/BUILDS.txt | cut -c1-160)"
  echo "workspace commit of B's worktree is in BUILDS.txt; job worktree $WT at $(git -C "$WT" rev-parse --short HEAD)"
} > "$OUT/run-info.txt"

python3 elmdiff/elmdiff.py --a ./bin/elm0193 --b "./bin/$B" \
  --pkgs corpus/pkgs --apps corpus/apps \
  --out "$OUT" --elm-home "$HOME_COPY" --timeout 180 $RESUME \
  > "$OUT/elmdiff.txt" 2>&1 || echo "elmdiff exit $?" >> "$OUT/run-info.txt"

# totals in the form of the gates summary step, plus a per mode count from results.jsonl
{
  awk -F'|' '/^\| [A-Z_]+ \| [0-9]+ \|$/{ if ($2 == " SAME ") s+=$3; else d+=$3 } END{printf "elmdiff: %d SAME, %d not SAME (packages and apps)\n", s, d}' "$OUT/summary.md"
  python3 -c '
import json, sys, collections
c = collections.Counter()
for line in open(sys.argv[1]):
    r = json.loads(line); c[(r["kind"], r["mode"], r["category"])] += 1
for k in sorted(c): print("%-4s %-9s %-20s %d" % (k + (c[k],)))
' "$OUT/results.jsonl"
} > "$OUT/totals.txt" 2>&1 || true
echo "compat-elmdiff end $(date '+%F %T')" >> "$OUT/run-info.txt"
cat "$OUT/totals.txt"
