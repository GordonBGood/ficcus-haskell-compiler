#!/bin/sh
# Night queue: submit one job.  [BIN=elmficX|/abs/path] [MINFREE_GB=8] nq/submit.sh NAME WORKTREE COMMIT STEP...
# STEP: build | a step name of WORKTREE/ficus-tests/gates.sh | run:FILE (sh FILE in the worktree). See docs/NQ.md.
set -eu
NQ=${NQ_DIR:-$(cd "$(dirname "$0")" && pwd)}
die() { echo "nq submit: $*" >&2; exit 2; }
[ $# -ge 4 ] || die "usage: [BIN=..] [MINFREE_GB=8] $0 NAME WORKTREE COMMIT STEP..."
NAME=$1; WT=$2; C=$3; shift 3
case $NAME in ''|*[!A-Za-z0-9._-]*) die "NAME may use only A-Z a-z 0-9 . _ -";; esac
WT=$(cd "$WT" 2>/dev/null && pwd) || die "no worktree $2"
COMMIT=$(git -C "$WT" rev-parse -q --verify "$C^{commit}") || die "no commit $C in $WT"
HEAD=$(git -C "$WT" rev-parse HEAD)
[ "$HEAD" = "$COMMIT" ] || die "$WT HEAD is $HEAD, not $COMMIT"
[ -z "$(git -C "$WT" status --porcelain --untracked-files=no)" ] || die "$WT has uncommitted changes"
BRANCH=$(git -C "$WT" symbolic-ref --short -q HEAD || echo detached)
GATES=$WT/ficus-tests/gates.sh; BUILD=; GATE=
for s in "$@"; do
  case $s in
    build) BUILD=1;;
    run:*) f=${s#run:}; case $f in /*) ;; *) f=$WT/$f;; esac; [ -f "$f" ] || die "no file $f";;
    *[!a-z0-9-]*|'') die "bad step '$s'";;
    *) grep -Eq "^step $s(;| |\$)" "$GATES" 2>/dev/null || die "no step '$s' in $GATES"; GATE=1;;
  esac
done
BIN=${BIN:-}; MINFREE_GB=${MINFREE_GB:-8}
case $MINFREE_GB in ''|*[!0-9]*) die "MINFREE_GB must be a whole number";; esac
[ -z "$GATE" ] || [ -n "$BUILD" ] || [ -n "$BIN" ] || die "gate steps need a build step or BIN"
mkdir -p "$NQ/jobs"
for j in "$NQ"/jobs/*-"$NAME".job; do [ -e "$j" ] && die "already pending: $j"; done
q() { printf "'%s'" "$(printf %s "$1" | sed "s/'/'\\\\''/g")"; }
F=$NQ/jobs/$(date +%Y%m%d-%H%M%S)-$NAME.job
{ echo "NAME=$(q "$NAME")"; echo "WORKTREE=$(q "$WT")"; echo "BRANCH=$(q "$BRANCH")"
  echo "COMMIT=$COMMIT"; echo "STEPS=$(q "$*")"; echo "BIN=$(q "$BIN")"
  echo "MINFREE_GB=$MINFREE_GB"; echo "SUBMITTED=$(q "$(date '+%F %T')")"; } > "$F.tmp"
mv "$F.tmp" "$F"; echo "queued $F"
