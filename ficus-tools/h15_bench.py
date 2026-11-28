#!/usr/bin/env python3
"""H15 part 2: hamnthstream (targets/hamnthstream) against the direct loop hamnth (targets/hamnth).

  python3 ficus-tools/h15_bench.py --elm bin/elmficNN --elm-home H --out DIR [--sizes 1000000,100000000,1000000000] [--runs 5] [--big-runs 3]

Ficus: (a) hamnth.fic, (b) HamNthStream.fic (CIS stream, Vector queue), (c) HamNthStreamList.fic (list queue, 10^6 only); --rc, gcc -O2
-ffp-contract=off, counters from a second build with -DFIC_STATS and a per-tag allocation count patched into a copy of the generated C
(closures, partial applications, strings, vectors). Hand C: hamnth.c (direct loop), the best of gcc/clang -O2/-O3. Rust: hamnth.rs (direct
loop), hamnthstream `iter` (Iterator::nth on the struct) and `dyn` (Box<dyn Iterator>, virtual next per element). Serial, `ulimit -v` 6 GB,
median wall time of --runs runs (--big-runs for 10^9), max RSS of one more run; all printed lines must be equal. Writes DIR/h15_bench.json."""
import argparse, json, os, re, shutil, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
from p1_bench import timed, patch_tags, counters, cap, sh, quiet  # noqa: E402

REPO = os.path.dirname(HERE); ROOT = os.path.dirname(REPO)
RT = os.path.join(ROOT, "targets", "c"); HN = os.path.join(REPO, "targets", "hamnth"); HS = os.path.join(REPO, "targets", "hamnthstream")
SAFE = os.path.join(HERE, "safe")


def lines(text):
    return [re.sub(r": \(\)$", "", l.strip()) for l in text.replace("\r", "").splitlines() if l.startswith(("Hamming number", "1", "2", "3", "4", "5", "6", "7", "8", "9"))]


def build_fic(a, d, name, srcdir, n):
    os.makedirs(os.path.join(d, "src"), exist_ok=True)
    shutil.copy(os.path.join(srcdir, "elm.json"), d)
    text = open(os.path.join(srcdir, "src", name + ".fic")).read()
    assert "\n    1000000\n" in text
    open(os.path.join(d, "src", name + ".fic"), "w").write(text.replace("\n    1000000\n", "\n    %d\n" % n, 1))
    env = dict(os.environ, ELM_HOME=os.path.abspath(a.elm_home))
    rc, msg = sh([SAFE, os.path.abspath(a.elm), "make", "src/%s.fic" % name, "--output=x.c", "--rc"], env=env, cwd=d)
    if rc != 0: raise SystemExit("compile %s: %s" % (name, msg[-500:]))
    run = os.path.join(d, "run"); stats = os.path.join(d, "stats")
    rc, msg = sh(["gcc", "-std=c99", "-O2", "-ffp-contract=off", "-w", "-I", RT, os.path.join(d, "x.c"), "-o", run, "-lm", "-lpthread"])
    if rc != 0: raise SystemExit("gcc: " + msg[-500:])
    xs = os.path.join(d, "xs.c"); shutil.copy(os.path.join(d, "x.c"), xs); patch_tags(xs)
    rc, msg = sh(["gcc", "-std=c99", "-O2", "-ffp-contract=off", "-w", "-DFIC_STATS", "-I", RT, xs, "-o", stats, "-lm", "-lpthread"])
    if rc != 0: raise SystemExit("gcc stats: " + msg[-500:])
    return run, stats


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--elm-home", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--sizes", default="1000000,100000000,1000000000"); ap.add_argument("--runs", type=int, default=5); ap.add_argument("--big-runs", type=int, default=3)
    ap.add_argument("--work", default=""); ap.add_argument("--only", default="")
    a = ap.parse_args()
    avail = [int(l.split()[1]) for l in open("/proc/meminfo") if l.startswith("MemAvailable:")][0] / 1048576.0
    if avail < 8: print("less than 8 GB available: not run"); return 1
    os.makedirs(a.out, exist_ok=True); work = a.work or os.path.join(a.out, "work")
    rf = os.path.join(a.out, "h15_bench.json"); res = json.load(open(rf)) if os.path.exists(rf) else {}
    only = set(filter(None, a.only.split(",")))
    for n in [int(x) for x in a.sizes.split(",")]:
        runs = a.big_runs if n >= 10**9 else a.runs
        r = res.setdefault(str(n), {}); shutil.rmtree(work, ignore_errors=True); os.makedirs(work)

        def meas(name, cmd, stats=None):
            if only and name not in only: return
            t = timed(cmd, runs); r[name] = {"ms": t[0], "rss_mb": t[1], "lines": lines(t[2]) if t[0] else t[2]}
            if stats:
                p = subprocess.run([stats], capture_output=True, preexec_fn=cap)
                r[name]["counters"] = counters((p.stdout + p.stderr).decode("utf-8", "replace"))
            print(n, name, "%s ms" % (round(t[0], 1) if t[0] else None), "%.1f MB" % t[1] if t[1] else "", r[name].get("counters", ""), flush=True)
            json.dump(res, open(rf, "w"), indent=1)

        variants = [("ficus_a_direct", "HamNth", HN), ("ficus_b_stream", "HamNthStream", HS)] + ([("ficus_c_list", "HamNthStreamList", HS)] if n <= 1000000 else [])
        for key, mod, sd in variants:
            if only and key not in only: continue
            run, stats = build_fic(a, os.path.join(work, key), mod, sd, n)
            meas(key, [run], stats)
        # hand C
        if not only or "hand_c" in only:
            best = None
            for cc in ("gcc", "clang"):
                for opt in ("-O2", "-O3"):
                    exe = os.path.join(work, "hand_%s%s" % (cc, opt))
                    rc, msg = sh([cc, "-std=c99", opt, "-ffp-contract=off", "-w", "-DTARGET=%d" % n, os.path.join(HN, "hamnth.c"), "-o", exe, "-lm"])
                    if rc != 0: raise SystemExit("hand C: " + msg[-300:])
                    t = timed([exe], runs)
                    if best is None or t[0] < best[0]: best = (t[0], exe, "%s %s" % (cc, opt))
            meas("hand_c_direct", [best[1]]); r["hand_c_direct"]["build"] = best[2]
        # Rust
        rx = lambda src, out: sh(["rustc", "--edition", "2021", "-C", "opt-level=3", "-C", "debug-assertions=no", "-A", "warnings", src, "-o", out])
        e1 = os.path.join(work, "rs_direct"); e2 = os.path.join(work, "rs_stream")
        rx(os.path.join(HN, "hamnth.rs"), e1); rx(os.path.join(HS, "hamnthstream.rs"), e2)
        meas("rust_direct", [e1, str(n)]); meas("rust_iter", [e2, str(n), "iter"]); meas("rust_dyn", [e2, str(n), "dyn"])
        ref = r.get("ficus_a_direct", {}).get("lines")
        r["agree"] = all(v.get("lines") == ref for k, v in r.items() if isinstance(v, dict) and "lines" in v)
        print(n, "all answers agree:", r["agree"], flush=True)
        json.dump(res, open(rf, "w"), indent=1)
        shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
