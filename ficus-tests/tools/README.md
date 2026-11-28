# Builder deadlock tools

Tools used to find the intermittent builder crash "thread blocked indefinitely in an MVar operation" (A4a, fixed by
`Details.forceInterface`). They work on any binary and any GHC eventlog.

| File | What it does |
|---|---|
| `mvloop.sh OUT N NET "RTS" BIN...` | N rounds of the reproducer; each round compiles the known15 rc mutant 216 (`FICUS_RC_MUTATE=216 make src/Known15.fic --rc`) once with each binary, interleaved, with an eventlog (`+RTS RTS -l`). NET is `online` or `offline` (`unshare -rn`, after one online warm-up that fills `OUT/home`). A run without `rc check:` in its output is a crash: its output and eventlog are kept as `OUT/crash-BIN-ROUND.{txt,eventlog}`, `OUT/log.txt` has a line per crash and every 250 rounds, `OUT/summary.txt` the counts. A binary is a name in `$FICUS_BIN` (default: the workspace `bin/`) or a path. |
| `evlog.py FILE` | Each thread of an eventlog: which thread created it, its last state (for example `BlockedOnBlackHole on 70`, `BlockedOnMVar`) and its label. |
| `evdump.py FILE [FROM_MS]` | The raw thread, GC and label events in time order, from FROM_MS milliseconds on. Needs `evlog.py` next to it. |
| `evcycle.py FILE...` | For each eventlog, the first GC at which two threads are blocked on blackholes owned by each other (the cycle) and every thread then blocked on a blackhole, with its owner. |
| `fork-label.diff` | A diagnostic patch of `ThreadSafe.Fork.fork`: each forked thread is labelled with its key (the module or package name), so `evlog.py` shows which module each thread compiles. Do not commit it. |

## Reproducing the deadlock

The crash needs many capabilities (none with `-N1`, `-N2` or `-N4` on 16 cores) and a short context switch interval
makes it frequent: with `+RTS -C0.001` an unfixed binary crashes in about 0.75% of the runs, against about 1 in
1,000 to 2,000 with the default settings.

    ficus-tests/tools/mvloop.sh /abs/out 1000 offline "-C0.001" elmficA4a elmficNEW
    python3 ficus-tests/tools/evcycle.py /abs/out/crash-*.eventlog

To see module names, apply `fork-label.diff`, build, and run `evlog.py` on a crash eventlog. In the A4a crashes the
cycle was always between two of the elm/core modules that import only Basics (Char, Maybe, Bitwise, Platform,
Elm.JsArray): they all start when Basics is done and evaluated Basics' lazily built interface at the same time.
The idle GC finds the cycle about 0.3 s later, and the threads waiting on their MVars get the exception.
