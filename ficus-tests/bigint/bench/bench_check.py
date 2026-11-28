#!/usr/bin/env python3
"""The benchmark programs (reduced sizes) in the three modes of the handoff: plain (counted, FIC_STATS: nonzero exit when objects are
live), FIC_DROP_ALL=1, and counted + ASan/UBSan (no pool, leaks reported); output compared with Python's."""
import os, subprocess, sys, tempfile
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
import bench

work = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="bcheck-")
os.makedirs(work, exist_ok=True)
bad = 0
for name in bench.NAMES:
    z = bench.ELM
    want = bench.expected(name, z)
    f = "%s/%s.fic" % (work, name)
    open(f, "w").write(bench.body(name, z, "fic"))
    for mode, bmode, env in (("plain", "stats", {}), ("dropall", "stats", {"FIC_DROP_ALL": "1"}), ("san", "san", {"ASAN_OPTIONS": "detect_leaks=1"})):
        exe = "%s/%s_%s" % (work, name, mode)
        r = subprocess.run([here + "/../bbuild.sh", f, exe, bmode], capture_output=True, text=True)
        if r.returncode:
            print(name, mode, "BUILD FAILED", r.stdout[-800:], r.stderr[-800:]); bad += 1; continue
        m = bench.timed([exe], env=dict(env, FIC_WARN_COPY="1"), timeout=300, rlimit=False)
        ok = m["code"] == 0 and want in m["out"]
        st = [l for l in m["err"].splitlines() if l.startswith("FIC_STATS")]
        warn = [l for l in m["err"].splitlines() if l.startswith("FIC_WARN_COPY")]
        print("%-8s %-8s %s  %s%s" % (name, mode, "OK " if ok else "BAD", (st[0][11:80] if st else m["err"][:150]), ("  [%d copy warning(s)]" % len(warn)) if warn else ""), flush=True)
        bad += 0 if ok else 1
sys.exit(1 if bad else 0)
