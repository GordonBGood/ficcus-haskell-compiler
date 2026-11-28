#!/bin/sh
# steady.sh CMD...: runs CMD 60 times in a row (the CPU clock ramps up: a cold first run is about 1.6 times slower) and prints the median of the
# last 40 runs in ms. For the Ficus benchmarks use targets/sort/sortbench.py --runs 60 --last 40 --patterns random --elm bin/elmficS4 (same rule,
# with the generation time subtracted).
n=${RUNS:-60}; last=${LAST:-40}
python3 - "$n" "$last" "$@" <<'PY'
import subprocess, sys, time, statistics
n, last, cmd = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3:]
ts = []
for _ in range(n):
    t = time.perf_counter(); subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); ts.append((time.perf_counter() - t) * 1e3)
print("median of the last %d of %d runs: %.1f ms" % (last, n, statistics.median(ts[-last:])))
PY
