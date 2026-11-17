#!/usr/bin/env python3
"""BigInt benchmarks: Ficcus (package in ../src), hand C on the same limbs (ref.c), GMP (gmpb.c), Elm package under node (reduced sizes).
Serial, median of N runs (wall seconds of the whole process), peak resident memory (ru_maxrss of the child), capped (address space
for native programs, a timeout for all).  Output lines of every implementation are compared with Python's.

  python3 bench.py [--runs 5] [--only fact,fib] [--impls ficcus,ref,gmp,elm] [--work DIR] [--json out.json]
"""
import argparse, json, math, os, re, resource, shutil, statistics, subprocess, sys, tempfile, time

here = os.path.dirname(os.path.abspath(__file__))
ws = os.path.abspath(os.path.join(here, "../../../.."))
sys.set_int_max_str_digits(0)

FULL = dict(FACT=10000, FIB=100000, POW=200000, DIG=209589, REP=10000, DEN=59200, DDIG=209589, MX=150000, MY=90000)
ELM = dict(FACT=2000, FIB=100000, POW=100000, DIG=100000, REP=10000, DEN=590, DDIG=2100, MX=1500, MY=1000)
NAMES = ["fact", "fib", "pow3", "build", "tostr", "fromstr", "divmod", "mulbig"]
LABEL = {"fact": "fact10000", "fib": "fib100000", "pow3": "pow3_200000", "build": "build", "tostr": "tostr", "fromstr": "fromstr", "divmod": "divmod"}


def summ(label, x):
    t = str(x)
    return '%s: "len=%d head=%s tail=%s"' % (label, len(t), t[:20], t[-20:])


def expected(name, z):
    if name == "fact":
        return summ("fact10000", math.factorial(z["FACT"]))
    if name == "fib":
        a, b = 0, 1
        for _ in range(z["FIB"]):
            a, b = b, a + b
        return summ("fib100000", a)
    if name == "pow3":
        return summ("pow3_200000", 3 ** z["POW"])
    if name == "build":
        return 'build: "positive"'
    if name == "tostr":
        return summ("tostr", 3 ** z["DIG"])
    if name == "fromstr":
        return 'fromstr: "odd False"'
    if name == "mulbig":
        x, y, acc = 3 ** z["MX"], 7 ** z["MY"], 0
        for i in range(5):
            acc += ((x + i) * y) % 1000000007
        return "mulbig: \"%d\"" % acc
    if name == "divmod":
        n, d, s = 3 ** z["DDIG"], 7 ** z["DEN"], 0
        for i in range(10):
            q, r = divmod(n + i, d)
            s += q + r
        return summ("divmod", s)


def body(name, z, ext):
    b = open(os.path.join(here, "body", name + ".fic")).read()
    for k, v in z.items():
        b = b.replace("@%s@" % k, str(v))
    return open(os.path.join(here, "prelude.fic")).read().replace("@BODY@", b)


def timed(cmd, env=None, timeout=300, rlimit=True, cwd=None):
    out = tempfile.TemporaryFile()
    err = tempfile.TemporaryFile()
    e = dict(os.environ)
    if env:
        e.update(env)

    def pre():
        if rlimit:
            resource.setrlimit(resource.RLIMIT_AS, (4 << 30, 4 << 30))
    t0 = time.perf_counter()
    tf = tempfile.NamedTemporaryFile(delete=False)
    tf.close()
    p = subprocess.Popen(["/usr/bin/time", "-f", "%M", "-o", tf.name] + cmd, stdout=out, stderr=err, env=e, preexec_fn=pre, cwd=cwd, start_new_session=True)
    killed = False
    while True:
        pid, status, ru = os.wait4(p.pid, os.WNOHANG)
        if pid:
            break
        if time.perf_counter() - t0 > timeout:
            os.killpg(p.pid, 9)
            killed = True
        time.sleep(0.005)
    dt = time.perf_counter() - t0
    try:
        rss = int(open(tf.name).read().split()[-1])
    except Exception:
        rss = 0
    os.unlink(tf.name)
    out.seek(0)
    err.seek(0)
    return dict(sec=dt, rss=rss, out=out.read().decode(errors="replace"), err=err.read().decode(errors="replace"),
                code=os.waitstatus_to_exitcode(status), killed=killed)


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--only", default=",".join(NAMES))
    ap.add_argument("--impls", default="ficcus,ref,gmp,elm")
    ap.add_argument("--work", default=None)
    ap.add_argument("--json", default=None)
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--karatsuba", type=int, default=None, help="Karatsuba threshold for the Ficcus package (build a patched copy)")
    a = ap.parse_args()
    work = a.work or tempfile.mkdtemp(prefix="bigint-bench-")
    os.makedirs(work, exist_ok=True)
    names = a.only.split(",")
    impls = a.impls.split(",")
    print("load average at start:", open("/proc/loadavg").read().strip())
    res = {}
    if "ref" in impls:
        sh(["gcc", "-O2", "-w", "-o", work + "/ref", here + "/ref.c"])
    if "gmp" in impls:
        r = sh(["gcc", "-O2", "-w", "-o", work + "/gmpb", here + "/gmpb.c", "-lgmp"])
        if r.returncode != 0:
            print("libgmp not usable:", r.stderr[:200])
            impls.remove("gmp")
    env = {}
    srcdir = here + "/../src"
    for name in names:
        res[name] = {}
        for impl in impls:
            z = ELM if impl in ("elm", "ficcus-s") else FULL
            want = expected(name, z)
            if impl in ("ficcus", "ficcus-s"):
                f = "%s/%s%s.fic" % (work, name, impl[6:])
                open(f, "w").write(body(name, z, "fic"))
                bb = here + "/../bbuild.sh"
                r = sh([bb, f, work + "/" + name + impl[6:] + "_fic", "fast"])
                if r.returncode:
                    print(name, "ficcus build failed", r.stdout[-2000:], r.stderr[-2000:]); continue
                r = sh([bb, f, work + "/" + name + impl[6:] + "_fics", "stats"])
                cmd = [work + "/" + name + impl[6:] + "_fic"]
                st = timed([work + "/" + name + impl[6:] + "_fics"], env={"FIC_WARN_COPY": "1"}, timeout=a.timeout)
                counters = " ".join(l[11:] for l in st["err"].splitlines() if l.startswith("FIC_STATS"))
                warns = [l for l in st["err"].splitlines() if l.startswith("FIC_WARN_COPY")]
            elif impl == "ref":
                cmd = [work + "/ref", name]; counters = ""; warns = []
            elif impl == "gmp":
                cmd = [work + "/gmpb", name]; counters = ""; warns = []
            elif impl == "elm":
                d = "%s/elm_%s" % (work, name)
                os.makedirs(d + "/src", exist_ok=True)
                open(d + "/src/Main.elm", "w").write(body(name, z, "elm"))
                pk = ws + "/corpus/pkgs/cmditch/elm-bigint/src"
                for fn in ("BigInt.elm", "Constants.elm"):
                    shutil.copy(pk + "/" + fn, d + "/src/" + fn)
                open(d + "/elm.json", "w").write('{"type":"application","source-directories":["src"],"elm-version":"0.19.3","dependencies":{"direct":{"elm/core":"1.0.5","elm-community/list-extra":"8.7.0","elm-community/maybe-extra":"5.3.0","rtfeldman/elm-hex":"1.0.0"},"indirect":{"elm/json":"1.1.3"}},"test-dependencies":{"direct":{},"indirect":{}}}')
                open(d + "/run.js", "w").write("const {Elm}=require('./main.js');Elm.Main.init();")
                r = subprocess.run([ws + "/bin/elm0193", "make", "src/Main.elm", "--output=main.js"], cwd=d, capture_output=True, text=True,
                                   env=dict(os.environ, ELM_HOME=ws + "/elm-home-difftest/0.19.3"))
                if r.returncode:
                    print(name, "elm build failed", r.stdout[-1500:], r.stderr[-1500:]); continue
                cmd = ["node", "--max-old-space-size=3072", d + "/run.js"]; counters = ""; warns = []
            times, rss, ok = [], [], True
            for i in range(a.runs):
                m = timed(cmd, timeout=a.timeout, rlimit=(impl != "elm"))
                times.append(m["sec"]); rss.append(m["rss"])
                if m["killed"] or m["code"] != 0 or want not in m["out"]:
                    ok = False
                    print("  %s/%s run %d: killed=%s code=%s out=%r" % (name, impl, i, m["killed"], m["code"], m["out"][:200] + m["err"][:200]))
                    break
            res[name][impl] = dict(median=statistics.median(times) if times else None, min=min(times) if times else None,
                                   max=max(times) if times else None, rss_kb=max(rss) if rss else None, ok=ok, counters=counters,
                                   copy_warnings=warns, runs=len(times), sizes=(z if impl in ("elm", "ficcus-s") else "full"))
            r = res[name][impl]
            print("%-8s %-7s median %.3fs (min %.3f max %.3f) rss %d MB %s %s" % (name, impl, r["median"] or -1, r["min"] or -1, r["max"] or -1,
                  (r["rss_kb"] or 0) // 1024, "OK" if ok else "WRONG", counters[:110]), flush=True)
            for w in warns:
                print("    ", w[:200])
    if a.json:
        json.dump(res, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
