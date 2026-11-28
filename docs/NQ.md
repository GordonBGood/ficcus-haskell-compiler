# NQ: the night queue

Plain POSIX sh in `nq/`; no daemon, no cron. State (ignored by git): `nq/jobs` pending, `nq/done` and `nq/failed`
finished jobs, `nq/done/NAME.summary`, `nq/logs/NAME.log`, `nq/bin/NAME-elm` (binary of a build step).

**Submit.** `[BIN=elmficX] [MINFREE_GB=8] nq/submit.sh NAME WORKTREE COMMIT STEP...` writes
`nq/jobs/<timestamp>-NAME.job` (shell key=value). Refused when HEAD is not COMMIT, tracked files are changed
(untracked files are allowed), a step is unknown, or NAME is already pending. A STEP is

- `build`: `cabal -j1 build exe:elm --ghc-options="+RTS -M6g -RTS"` in the worktree (GHC itself runs -j1, no `-j`
  in elm.cabal); writes only the ignored `dist-newstyle`; the binary is copied to `nq/bin` and used by later gate steps;
- a step name of the worktree's `ficcus-tests/gates.sh` (`attach`, `types`, ... `summary`); needs `build` or `BIN`
  (a name in `bin/` or an absolute path). Consecutive gate steps run as one gates.sh run, generated from gates.sh
  with only those steps, its lock lines removed and W, R, B fixed;
- `run:FILE`: `sh FILE` in the worktree; passes on exit 0.

**Run.** `nq/run.sh [--until HH:MM] [--once]` runs pending jobs in name order. Per job: wait until MemAvailable
>= MINFREE_GB, take the gate lock (the same file as gates.sh: `${CLAUDE_CODE_TMPDIR:-/tmp}/ficcus-gates.lock`, so
start it from a shell with the sessions' CLAUDE_CODE_TMPDIR, `/home/gordon/claude-tmp`), check HEAD and the tree
again (else `stale`), run every step, write the summary, move the job. Without `--until` it stops when the queue is
empty; with it, it waits for later submissions and starts no job after HH:MM. `--once` runs one job.

**Verdicts.** Gate steps are judged on their printed tails: FAIL (not XFAIL), REGRESSION, Traceback, missing files,
a nonzero "differ/failed/missed/DIFF/not PASS" count, a nonzero `runtime` count. Expected nonzero counts
show as fail: read the tail in the summary.

**Morning.** `nq/report.sh ["since"]` (default "14 hours ago") prints one table.
