#!/usr/bin/env python3
"""V1 sanity measurement (docs/STAGE4-V1.md): the Vector versions of the scaled sieve and of fannkuch against the hand written C,
safe Rust and the Array versions.

  python3 ficus-tools/v1_bench.py --elm bin/elmficNN --elm-home H --out DIR [--runs 5]

Serial, one process at a time, median wall time of --runs runs of the whole program (process start included), every program under
`ulimit -v` 6 GB; refuses to run with less than 8 GB available. Ficus: `--rc`, gcc -O2 -ffp-contract=off (and clang -O3 as a second
column). Hand C: gcc and clang at -O2 and -O3, the best is reported with its build. Rust: rustc --edition 2021 -C opt-level=3, safe.
The answers of all versions of a program must agree (the integers they print). Writes DIR/v1_bench.json and prints two tables."""
import argparse, json, os, re, resource, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
ROOT = os.path.dirname(REPO)
RT = os.path.join(ROOT, "targets", "c")
SC = os.path.join(REPO, "targets", "scaled")

# name, hand C [(label, file, flags)], Rust file, Array source, Vector source.
# The hand C programs do the work once for the answer and then NUMLOOPS more times for their own timing (sieve_plain.c: 1, fannkuch.c: 5):
# with -DNUMLOOPS=0 the process does the work ONCE, like the Ficus and Rust programs. (primebench_unrolled.c has only the timed loop.)
PROGRAMS = [
    ("sieve (1 MB buffer)", [("hand C plain", os.path.join(SC, "sieve", "sieve_plain.c"), ["-DNUMLOOPS=0"]), ("hand C unrolled", os.path.join(SC, "sieve", "primebench_unrolled.c"), ["-DNUMLOOPS=1"])],
     os.path.join(SC, "sieve", "sieve.rs"), os.path.join(SC, "sieve", "src", "Sieve.elm"), os.path.join(SC, "sieve_vec", "src", "SieveVec.fic")),
    ("fannkuch (n = 10)", [("hand C", os.path.join(RT, "fannkuch.c"), ["-DNUMLOOPS=0"])],
     os.path.join(REPO, "targets", "rust", "fannkuch.rs"), os.path.join(REPO, "ficus-tests", "fannkuch", "src", "Fannkuch.fic"),
     os.path.join(SC, "fannkuch_vec", "src", "FannkuchVec.fic")),
]


def cap():
    resource.setrlimit(resource.RLIMIT_AS, (6 << 30, 6 << 30))


def sh(cmd, env=None):
    p = subprocess.run(cmd, capture_output=True, env=env)
    return p.returncode, (p.stdout + p.stderr).decode("utf-8", "replace")


def timed(exe, runs):
    ts, out = [], b""
    for _ in range(runs):
        t0 = time.perf_counter()
        p = subprocess.run([exe], capture_output=True, preexec_fn=cap)
        ts.append((time.perf_counter() - t0) * 1000)
        if p.returncode != 0: return None, p.stderr.decode("utf-8", "replace")[-200:]
        out = p.stdout
    return statistics.median(ts), out.decode("utf-8", "replace")


def answer(text):
    """the integers that matter: the first two of the sieve line, or all of fannkuch's"""
    m = re.search(r"Found (\d+)\D+?(\d+)", text)
    return [m.group(1), m.group(2)] if m else re.findall(r"-?\d+", text)[:3]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--elm-home", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--runs", type=int, default=5)
    a = ap.parse_args()
    avail = [int(l.split()[1]) for l in open("/proc/meminfo") if l.startswith("MemAvailable:")][0] / 1048576.0
    if avail < 8: print("less than 8 GB available: not run"); return 1
    os.makedirs(a.out, exist_ok=True)
    res = {}
    for k, (name, hands, rust, arr, vec) in enumerate(PROGRAMS):
        r = res.setdefault(name, {})
        for label, src in (("Ficus Array", arr), ("Ficus Vector", vec)):
            c = os.path.join(a.out, "p%d_%s.c" % (k, label.split()[1]))
            env = dict(os.environ, FICUS_ELM=os.path.abspath(a.elm), FICUS_FLAGS="--rc", ELM_HOME=os.path.abspath(a.elm_home))
            rc, msg = sh([os.path.join(REPO, "ficus-tests", "fic"), src, "-o", c], env=env)
            if rc != 0: print("FAIL", label, msg[-300:]); return 1
            for cc, opt in (("gcc", "-O2"), ("clang", "-O3")):
                exe = c[:-2] + "_" + cc
                rc, msg = sh([cc, "-std=c99", opt, "-ffp-contract=off", "-w", "-I", RT, c, "-o", exe, "-lm"])
                if rc != 0: print("FAIL", label, cc, msg[-300:]); return 1
                r["%s (%s %s)" % (label, cc, opt)] = timed(exe, a.runs)
            sx = c[:-2] + "_stats"
            sh(["gcc", "-std=c99", "-O2", "-ffp-contract=off", "-w", "-DFIC_STATS", "-I", RT, c, "-o", sx, "-lm"])
            p = subprocess.run([sx], capture_output=True, preexec_fn=cap)
            r[label + " counters"] = [l for l in p.stderr.decode().splitlines() if l.startswith("FIC_STATS")][-1]
        for label, src, flags in hands:
            best = None
            for cc in ("gcc", "clang"):
                for opt in ("-O2", "-O3"):
                    exe = os.path.join(a.out, "p%d_%s_%s%s" % (k, label.replace(" ", "_"), cc, opt))
                    rc, msg = sh([cc, "-std=c99", opt, "-ffp-contract=off", "-w"] + flags + ["-I", RT, src, "-o", exe, "-lm"])
                    if rc != 0: print("FAIL", label, cc, msg[-300:]); return 1
                    t, out = timed(exe, a.runs)
                    r["%s (%s %s)" % (label, cc, opt)] = (t, out)
                    if best is None or t < best[0]: best = (t, out, "%s %s" % (cc, opt))
            r[label + " best"] = best
        exe = os.path.join(a.out, "p%d_rust" % k)
        rc, msg = sh(["rustc", "--edition", "2021", "-C", "opt-level=3", rust, "-o", exe])
        if rc != 0: print("FAIL rustc", msg[-300:]); return 1
        r["Rust safe O3"] = timed(exe, a.runs)
        answers = {l: answer(v[1]) for l, v in r.items() if isinstance(v, (tuple, list)) and v[0] is not None}
        r["agree"] = len(set(tuple(x) for x in answers.values())) == 1
        print("\n%s   (answers agree: %s)" % (name, "yes" if r["agree"] else "NO %s" % answers))
        vec_t = r["Ficus Vector (gcc -O2)"][0]
        print("| version | ms | Vector (gcc -O2) / this |\n|---|---|---|")
        rows = ["Ficus Vector (gcc -O2)", "Ficus Vector (clang -O3)", "Ficus Array (gcc -O2)", "Ficus Array (clang -O3)"] + [l + " best" for l, _, _ in hands] + ["Rust safe O3"]
        for l in rows:
            v = r[l]
            print("| %s%s | %.1f | %.2f |" % (l.replace(" best", ""), " (best: %s)" % v[2] if len(v) > 2 else "", v[0], vec_t / v[0]))
        print("counters, Vector: " + r["Ficus Vector counters"])
        print("counters, Array:  " + r["Ficus Array counters"])
    json.dump(res, open(os.path.join(a.out, "v1_bench.json"), "w"), indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
