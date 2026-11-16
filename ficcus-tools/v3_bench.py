#!/usr/bin/env python3
"""V3 measurement (docs/STAGE4-V3.md): Vector versions of nbody, fannkuch, spectral, sieve and hamvec against the Array versions,
the hand written C (best of gcc/clang -O2/-O3) and safe Rust.

  python3 ficcus-tools/v3_bench.py --elm bin/elmficNN --elm-home H --out DIR [--runs 5] [--only a,b] [--experiments]

Serial, one process at a time, median wall time of --runs runs of the whole process, every run under `ulimit -v` 6 GB; refuses to
run with less than 8 GB available. The work is done ONCE by every version (hand C copies are patched in DIR: NUMLOOPS 0, nbody's
loop count 0); the answers of all versions of a program must agree. Ficcus columns: --rc, gcc -O2 -ffp-contract=off (the default
build). --experiments adds the V3 experiments: gcc -O3, clang -O2/-O3, each
reported as a ratio to the default build. Writes DIR/v3_bench.json."""
import argparse, json, os, re, resource, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
ROOT = os.path.dirname(REPO)
RT = os.path.join(ROOT, "targets", "c")
SC = os.path.join(REPO, "targets", "scaled")
VEC = os.path.join(REPO, "targets", "vec")
EL = os.path.join(ROOT, "targets", "elm")


def first(d):
    return os.path.join(d, "src", sorted(os.listdir(os.path.join(d, "src")))[0])


# name, Array source, Vector source, hand C [(label, file, flags, sed)], Rust file
PROGRAMS = [
    ("nbody", os.path.join(EL, "nbody", "src", "NBody.elm"), first(os.path.join(VEC, "nbody")),
     [("hand C", os.path.join(RT, "nbody.c"), [], ("const int NUMLOOPS = 5;", "const int NUMLOOPS = 0;"))],
     os.path.join(REPO, "targets", "rust", "nbody.rs")),
    ("fannkuch", os.path.join(REPO, "ficcus-tests", "fannkuch", "src", "Fannkuch.fic"), first(os.path.join(VEC, "fannkuch")),
     [("hand C", os.path.join(RT, "fannkuch.c"), ["-DNUMLOOPS=0"], None)], os.path.join(REPO, "targets", "rust", "fannkuch.rs")),
    ("spectral", os.path.join(EL, "spectral", "src", "Spectral.elm"), first(os.path.join(VEC, "spectral")),
     [("hand C", os.path.join(RT, "spectral.c"), ["-DNUMLOOPS=0"], None)], os.path.join(REPO, "targets", "rust", "spectral.rs")),
    ("sieve (1 MB)", os.path.join(SC, "sieve", "src", "Sieve.elm"), first(os.path.join(VEC, "sieve")),
     [("hand C plain", os.path.join(SC, "sieve", "sieve_plain.c"), ["-DNUMLOOPS=0"], None),
      ("hand C unrolled", os.path.join(SC, "sieve", "primebench_unrolled.c"), ["-DNUMLOOPS=1"], None)],
     os.path.join(SC, "sieve", "sieve.rs")),
    ("hamvec (1000 reps)", os.path.join(SC, "hamvec", "src", "HammingVec.elm"), first(os.path.join(VEC, "hamvec")),
     [("hand C", os.path.join(SC, "hamvec", "hamvec.c"), [], None)], os.path.join(SC, "hamvec", "hamvec.rs")),
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
        if p.returncode != 0: return None, "exit %d: %s" % (p.returncode, p.stderr.decode("utf-8", "replace")[-200:])
        out = p.stdout + p.stderr
    return statistics.median(ts), out.decode("utf-8", "replace")


def answer(text):
    """the lines that carry the answer: no timing or progress lines, Debug.log's ': ()' removed, numbers only for the sieve / Hamming lines"""
    lines = []
    for l in text.replace("\r", "").splitlines():
        l = l.strip()
        if not l or l.startswith("(") or l.startswith("Running") or l.startswith("FIC_STATS"): continue
        l = re.sub(r": \(\)$", "", l)
        m = re.match(r"(Found \d+ [A-Za-z ]+?\d+)", l)
        if l.startswith("Found"):
            n = re.findall(r"\d+", l); l = "Found " + " ".join(n[:2])
        lines.append(l)
    return lines


def stage(a, src, tag):
    """a copy of the source in its own project with elm-version 0.19.3 (the targets/elm projects say 0.19.1)"""
    d = os.path.join(a.out, "proj_" + tag)
    os.makedirs(os.path.join(d, "src"), exist_ok=True)
    open(os.path.join(d, "elm.json"), "w").write(open(os.path.join(VEC, "nbody", "elm.json")).read())
    dst = os.path.join(d, "src", os.path.basename(src))
    open(dst, "w").write(open(src).read())
    return dst


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--elm-home", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--runs", type=int, default=5); ap.add_argument("--only", default="")
    ap.add_argument("--experiments", action="store_true")
    a = ap.parse_args()
    avail = [int(l.split()[1]) for l in open("/proc/meminfo") if l.startswith("MemAvailable:")][0] / 1048576.0
    if avail < 8: print("less than 8 GB available: not run"); return 1
    os.makedirs(a.out, exist_ok=True)
    only = [x for x in a.only.split(",") if x]
    res = {}
    for k, (name, arr, vec, hands, rust) in enumerate(PROGRAMS):
        if only and not any(name.startswith(o) for o in only): continue
        r = res.setdefault(name, {})
        base = lambda s: os.path.join(a.out, "p%d_%s" % (k, s))
        genv = lambda extra=None: dict(os.environ, FICCUS_ELM=os.path.abspath(a.elm), FICCUS_FLAGS="--rc", ELM_HOME=os.path.abspath(a.elm_home), **(extra or {}))
        # Ficcus: (label, source, compiler env, cc, opt)
        arr = stage(a, arr, "p%d_array" % k)
        variants = [("Array", arr, {}, "gcc", "-O2"), ("Vector", vec, {}, "gcc", "-O2")]
        if a.experiments:
            variants += [("Vector", vec, {}, "gcc", "-O3"), ("Vector", vec, {}, "clang", "-O2"), ("Vector", vec, {}, "clang", "-O3"),
                         ("Array", arr, {}, "gcc", "-O3"), ("Array", arr, {}, "clang", "-O3")]
        cfiles = {}
        for label, src, cenv, cc, opt in variants:
            ck = (label, src, tuple(sorted(cenv.items())))
            if ck not in cfiles:
                c = base("%s_%d.c" % (label.replace("+", "_"), len(cfiles)))
                rc, msg = sh([os.path.join(REPO, "ficcus-tests", "ficc"), src, "-o", c], env=genv(cenv))
                if rc != 0: print("FAIL", name, label, msg[-300:]); return 1
                cfiles[ck] = c
            c = cfiles[ck]
            exe = c[:-2] + "_" + cc + opt.replace("-", "")
            rc, msg = sh([cc, "-std=c99", opt, "-ffp-contract=off", "-w", "-I", RT, c, "-o", exe, "-lm"])
            if rc != 0: print("FAIL", name, label, cc, msg[-300:]); return 1
            r["Ficcus %s (%s %s)" % (label, cc, opt)] = timed(exe, a.runs)
        sx = cfiles[("Vector", vec, ())] [:-2] + "_stats"
        sh(["gcc", "-std=c99", "-O2", "-ffp-contract=off", "-w", "-DFIC_STATS", "-I", RT, cfiles[("Vector", vec, ())], "-o", sx, "-lm"])
        p = subprocess.run([sx], capture_output=True, preexec_fn=cap)
        st = [l for l in p.stderr.decode().splitlines() if l.startswith("FIC_STATS")]
        r["Vector counters"] = st[-1] if st else ""
        for label, src, flags, sed in hands:
            best = None
            hsrc = src
            if sed:
                hsrc = base(os.path.basename(src))
                open(hsrc, "w").write(open(src).read().replace(*sed))
            for cc in ("gcc", "clang"):
                for opt in ("-O2", "-O3"):
                    exe = base("%s_%s%s" % (label.replace(" ", "_"), cc, opt))
                    rc, msg = sh([cc, "-std=c99", opt, "-ffp-contract=off", "-w"] + flags + ["-I", RT, "-I", os.path.dirname(src), hsrc, "-o", exe, "-lm"])
                    if rc != 0: print("FAIL", label, cc, msg[-300:]); return 1
                    t, out = timed(exe, a.runs)
                    r["%s (%s %s)" % (label, cc, opt)] = (t, out)
                    if t is not None and (best is None or t < best[0]): best = (t, out, "%s %s" % (cc, opt))
            r[label + " best"] = best
        exe = base("rust")
        rc, msg = sh(["rustc", "--edition", "2021", "-C", "opt-level=3", rust, "-o", exe])
        if rc != 0: print("FAIL rustc", msg[-300:]); return 1
        r["Rust safe O3"] = timed(exe, a.runs)
        ref = answer(r["Ficcus Array (gcc -O2)"][1])
        bad = [l for l, v in r.items() if isinstance(v, (tuple, list)) and v[0] is not None and answer(v[1]) != ref]
        r["agree"] = not bad
        print("\n%s   (answers agree: %s)" % (name, "yes" if not bad else "NO: %s" % bad), flush=True)
        vt = r["Ficcus Vector (gcc -O2)"][0]
        print("| version | ms | Vector (gcc -O2) / this |\n|---|---|---|")
        for l, v in r.items():
            if isinstance(v, (tuple, list)) and v[0] is not None and (l.startswith("Ficcus") or l.endswith(" best") or l.startswith("Rust")):
                print("| %s%s | %.1f | %.2f |" % (l.replace(" best", ""), " (best: %s)" % v[2] if len(v) > 2 and v[2] else "", v[0], vt / v[0]), flush=True)
        print("counters, Vector: " + r["Vector counters"], flush=True)
        json.dump(res, open(os.path.join(a.out, "v3_bench.json"), "w"), indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
