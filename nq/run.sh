#!/bin/sh
# Night queue runner.  nq/run.sh [--until HH:MM] [--once]   (see docs/NQ.md)
# Runs pending jobs in name order, one at a time, under the gate lock of ficcus-tests/gates.sh. Never pushes; never
# writes the worktree's tracked files (a build step writes only its ignored dist-newstyle).
set -u
NQ=${NQ_DIR:-$(cd "$(dirname "$0")" && pwd)}
LOCK=${NQ_LOCK:-${CLAUDE_CODE_TMPDIR:-/tmp}/ficcus-gates.lock}   # the same expression as gates.sh
POLL=${NQ_POLL:-60}; DEADLINE=; ONCE=
while [ $# -gt 0 ]; do
  case $1 in
    --until) DEADLINE=$(date -d "$2" +%s) || exit 2; [ "$DEADLINE" -gt "$(date +%s)" ] || DEADLINE=$((DEADLINE + 86400)); shift 2;;
    --once) ONCE=1; shift;;
    *) echo "usage: $0 [--until HH:MM] [--once]" >&2; exit 2;;
  esac
done
mkdir -p "$NQ/jobs" "$NQ/done" "$NQ/failed" "$NQ/logs" "$NQ/bin"
say() { echo "nq $(date +%T) $*"; }
past() { [ -n "$DEADLINE" ] && [ "$(date +%s)" -ge "$DEADLINE" ]; }
memgb() { awk '/^MemAvailable:/{print int($2/1048576)}' /proc/meminfo; }
FAILRE='Traceback|REGRESSION|(^|[^X])FAIL|No such file|cannot open|command not found|(^|[^0-9.])[1-9][0-9]* (differ|failed|missed|DIFF|not PASS)'

# the gates.sh text with only the steps in $1 (space separated), without its lock, with W, R and B fixed
gates_subset() {
  awk -v want=" $1 " -v w="$(dirname "$WORKTREE")" -v r="$WORKTREE" -v b="$BINPATH" '
    /^W=\$\(cd/ { print "W=" w "; R=" r; next }
    /^LOCK=|flock/ { next }
    /^B=/ { sub(/^B=[^;]*;/, "B=" b ";") }
    /^step [a-z0-9-]+/ { n = $2; sub(/;.*/, "", n); cur = n; if (index(want, " " n " ")) print; if (n != "summary") cur = ""; next }
    /^echo "=== DONE/ { cur = "" }
    cur == "summary" && !index(want, " summary ") { next }
    { print }' "$WORKTREE/ficcus-tests/gates.sh"
}

# per-step verdicts of one gates run: the log lines from $1 on, the steps $2; prints "name status seconds" lines
gate_verdicts() {
  tail -n +"$1" "$LOG" | awk -v want="$2" -v endt="$(date +%T)" -v re="$FAILRE" '
    function sec(t,  a) { split(t, a, ":"); return a[1]*3600 + a[2]*60 + a[3] }
    function close_(t,  d) { if (cur == "") return; d = sec(t) - sec(st); if (d < 0) d += 86400; dur[cur] = d; cur = "" }
    /^=== [a-z0-9-]+ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ { close_($3); if ($2 == "DONE") next; cur = $2; st = $3; seen[cur] = 1; first[cur] = 1; next }
    cur != "" { if ($0 ~ re) bad[cur] = 1; if (cur == "runtime" && first[cur] && $0 != "0") bad[cur] = 1; first[cur] = 0 }
    END { close_(endt); n = split(want, w, " ")
          for (i = 1; i <= n; i++) { s = w[i]; print s, (!seen[s] ? "missing" : bad[s] ? "fail" : "pass"), dur[s] + 0 } }'
}

# the last 30 lines of gate step $2 in the log lines from $1 on
gate_tail() {
  tail -n +"$1" "$LOG" | awk -v s="$2" '/^=== [a-z0-9-]+ [0-9:]+$/ { on = ($2 == s) } on' | tail -30
}

record() {   # step status seconds [tailfile]
  echo "STEP $1 $2 ${3}s" >> "$STEPF"
  if [ "$2" != pass ] && [ -z "$FIRST" ]; then FIRST=$1; [ -n "${4:-}" ] && cp "$4" "$TAILF"; fi
}

flush_gates() {
  [ -n "$GROUP" ] || return 0
  echo "=== nq gates:$GROUP $(date +%T)" >> "$LOG"
  start=$(($(wc -l < "$LOG") + 1)); gs=$WORK/gates-subset.sh
  gates_subset "$GROUP" > "$gs"
  S= bash "$gs" >> "$LOG" 2>&1; rc=$?
  gate_verdicts "$start" "$GROUP" > "$WORK/verdicts"
  while read -r gn st d; do
    gate_tail "$start" "$gn" > "$WORK/tail"; record "$gn" "$st" "$d" "$WORK/tail"
  done < "$WORK/verdicts"
  [ $rc -eq 0 ] || { tail -30 "$LOG" > "$WORK/tail"; record "gates-exit" "fail(rc=$rc)" 0 "$WORK/tail"; }
  GROUP=
}

run_one() {   # step: build or run:FILE
  echo "=== nq $1 $(date +%T)" >> "$LOG"
  start=$(($(wc -l < "$LOG") + 1)); t0=$(date +%s)
  case $1 in
    build) ( cd "$WORKTREE" && cabal -j1 build exe:elm --ghc-options="+RTS -M6g -RTS" &&
             cp "$(cabal list-bin exe:elm)" "$NQ/bin/$NAME-elm" ) >> "$LOG" 2>&1; rc=$?
           [ $rc -eq 0 ] && BINPATH=$NQ/bin/$NAME-elm;;
    run:*) f=${1#run:}; ( cd "$WORKTREE" && sh "$f" ) >> "$LOG" 2>&1; rc=$?;;
  esac
  tail -n +"$start" "$LOG" | tail -30 > "$WORK/tail"
  if [ $rc -eq 0 ]; then st=pass; else st="fail(rc=$rc)"; fi
  record "$1" "$st" $(($(date +%s) - t0)) "$WORK/tail"
}

summary() {   # result
  { echo "NAME=$NAME"; echo "RESULT=$1"; echo "WORKTREE=$WORKTREE"; echo "BRANCH=$BRANCH"; echo "COMMIT=$COMMIT"
    echo "STEPS=$STEPS"; echo "SUBMITTED=$SUBMITTED"; echo "STARTED=$T0"; echo "FINISHED=$(date +%s)"
    echo "SECONDS=$(($(date +%s) - T0))"; echo "FIRST_FAIL=${FIRST:--}"; echo "LOG=$LOG"; echo
    cat "$STEPFILE" 2>/dev/null
    [ -n "$FIRST" ] && [ -s "$TAILF" ] && { echo; echo "--- last 30 lines of $FIRST"; cat "$TAILF"; }
  } > "$NQ/done/$NAME.summary"
}

run_job() (   # a subshell: the lock (fd 9) is released when it ends
  JOB=$1; NAME= WORKTREE= BRANCH= COMMIT= STEPS= BIN= MINFREE_GB=8 SUBMITTED=
  . "$JOB"
  while [ "$(memgb)" -lt "$MINFREE_GB" ]; do
    past && { say "$NAME: $(memgb) GB available < $MINFREE_GB GB and past --until: left pending"; exit 3; }
    say "$NAME: waiting for $MINFREE_GB GB available (now $(memgb))"; sleep "$POLL"
  done
  exec 9>"$LOCK"
  if ! flock -n 9; then say "$NAME: waiting for the gate lock $LOCK"; flock 9; fi
  say "$NAME: started (lock taken)"
  LOG=$NQ/logs/$NAME.log; WORK=$(mktemp -d "${CLAUDE_CODE_TMPDIR:-${TMPDIR:-/tmp}}/nq.XXXXXX")
  trap 'rm -rf "$WORK"' EXIT; trap 'exit 143' TERM INT
  STEPF=$WORK/steps; STEPFILE=$STEPF; TAILF=$WORK/firsttail; FIRST=; T0=$(date +%s); : > "$STEPF"
  { echo "=== nq job $JOB $(date '+%F %T')"; cat "$JOB"; } > "$LOG"
  case $BIN in '') BINPATH=;; /*) BINPATH=$BIN;; *) BINPATH=$(dirname "$WORKTREE")/bin/$BIN;; esac
  HEAD=$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null)
  if [ "$HEAD" != "$COMMIT" ] || [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=no)" ]; then
    echo "stale: HEAD ${HEAD:-?} (job $COMMIT) or uncommitted changes" | tee -a "$LOG" > "$TAILF"; FIRST=stale
    summary stale; mv "$JOB" "$NQ/failed/"; say "$NAME: stale"; exit 0
  fi
  GROUP=
  for js in $STEPS; do
    case $js in
      build|run:*) flush_gates; run_one "$js";;
      *) GROUP=${GROUP:+$GROUP }$js;;
    esac
  done
  flush_gates
  if [ -z "$FIRST" ]; then summary pass; mv "$JOB" "$NQ/done/"; say "$NAME: pass"
  else summary fail; mv "$JOB" "$NQ/failed/"; say "$NAME: FAIL at $FIRST"; fi
)

while :; do
  JOB=$(ls "$NQ"/jobs/*.job 2>/dev/null | head -1)
  if past; then say "past --until: no new jobs started"; break; fi
  if [ -z "$JOB" ]; then
    [ -n "$DEADLINE" ] && [ -z "$ONCE" ] && { sleep "$POLL"; continue; }   # with --until: wait for later submissions
    say "queue empty"; break
  fi
  run_job "$JOB"; [ $? -eq 3 ] && break
  [ -n "$ONCE" ] && break
done
