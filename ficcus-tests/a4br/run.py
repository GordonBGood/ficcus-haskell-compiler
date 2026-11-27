#!/usr/bin/env python3
"""run.py -- the scratch cases of the A4b review (docs/A4B-REVIEW.md).  Standard library only.

  python3 ficcus-tests/a4br/run.py [--elm bin/elmficA4bb] [--only a,b] [--js] [-v]

Each case is cases/<id>/ with Main.elm (and other modules), and optionally twin/ (a plain Elm program whose output is the
expected one: compiled by bin/elm0193, run by node) or expected.out (the expected stdout, for cases with no Elm twin).
For each case the Ficcus program is compiled to C with --no-rc (gcc -O2) and with --rc (gcc -O1, ASan+UBSan, FIC_STATS,
FIC_NO_POOL); both outputs must equal the twin's, and the counted run must end with 0 live objects.  A compile failure
prints the report (several cases are expected rejections: see the README).  --js also compiles to JavaScript and prints
the result ."""
import argparse, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "attach"))
import attach, mkhome

ROOT = attach.ROOT
RT = os.path.join(ROOT, "targets", "c")


def setup(src, dst):
    os.makedirs(dst)
    shutil.copytree(src, os.path.join(dst, "src"), ignore=shutil.ignore_patterns("twin", "case.json", "*.md", "expected.out"))
    import json
    json.dump(attach.elm_json([]), open(os.path.join(dst, "elm.json"), "w"))


def one(cid, elm, home, verbose, js):
    src = os.path.join(HERE, "cases", cid)
    work = tempfile.mkdtemp(prefix="a4br-")
    env = dict(os.environ, ELM_HOME=home)
    res = []
    try:
        exp = None
        if os.path.isdir(os.path.join(src, "twin")):
            t = os.path.join(work, "twin"); setup(os.path.join(src, "twin"), t)
            rc, out = attach.run([os.path.join(ROOT, "bin", "elm0193"), "make", "src/Main.elm", "--output=out.js"], t, env)
            if rc != 0: return ["TWIN-FAIL " + out[-600:]]
            p = subprocess.run(["node", "-e", "require('./out.js').Elm.Main.init()"], cwd=t, capture_output=True, text=True, timeout=60)
            exp = p.stdout
        elif os.path.exists(os.path.join(src, "expected.out")):
            exp = open(os.path.join(src, "expected.out")).read()
        d = os.path.join(work, "p"); setup(src, d)
        if js:
            rc, out = attach.run([elm, "make", "src/Main.elm", "--output=x.js"], d, env, limit=300)
            if rc != 0:
                res.append("js REJECT:\n%s" % out.strip()[-1200:])
            else:
                p = subprocess.run(["node", "-e", "require('./x.js').Elm.Main.init()"], cwd=d, capture_output=True, text=True, timeout=60)
                ok = exp is None or p.stdout == exp
                res.append("js %s %s" % ("ok" if ok else "DIFFERS", p.stdout.strip()))
        for mode in ("--no-rc", "--rc"):
            rc, out = attach.run([elm, "make", "src/Main.elm", "--output=x.c", mode], d, env, limit=300)
            if rc != 0:
                res.append("%s COMPILE-FAIL:\n%s" % (mode, out.strip()[-1500:])); break
            if mode == "--no-rc":
                flags = ["gcc", "-std=c99", "-O2", "-ffp-contract=off", "-w"]
            else:
                flags = ["gcc", "-std=c99", "-O1", "-ffp-contract=off", "-w", "-DFIC_STATS", "-DFIC_NO_POOL", "-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-g"]
            exe = os.path.join(d, "x" + mode)
            b = subprocess.run(flags + ["-I", RT, os.path.join(d, "x.c"), "-o", exe, "-lm"], capture_output=True, text=True)
            if b.returncode != 0: res.append("%s CC-FAIL %s" % (mode, b.stderr[-800:])); continue
            r = subprocess.run([exe], capture_output=True, text=True, timeout=120)
            bad = []
            if r.returncode != 0: bad.append("exit %d" % r.returncode)
            if exp is not None and r.stdout != exp: bad.append("OUTPUT DIFFERS")
            if mode == "--rc" and " live 0 " not in r.stderr: bad.append("live objects: " + r.stderr.strip()[-200:])
            if bad or exp is None or verbose:
                res.append("%s %s\n--- got\n%s--- stderr\n%s" % (mode, ", ".join(bad) or "ran", r.stdout, r.stderr[-800:]) + ("--- expected\n" + exp if exp is not None and bad else ""))
            else:
                res.append("%s ok" % mode)
        return res
    finally:
        if not os.environ.get("KEEP"): shutil.rmtree(work, ignore_errors=True)
        else: print("kept", work)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", default=os.path.join(ROOT, "bin", "elmficA4bb")); ap.add_argument("--only"); ap.add_argument("-v", action="store_true")
    ap.add_argument("--js", action="store_true")
    a = ap.parse_args()
    ids = a.only.split(",") if a.only else sorted(os.listdir(os.path.join(HERE, "cases")))
    home = tempfile.mkdtemp(prefix="a4br-home-"); mkhome.make(home)
    try:
        for cid in ids:
            print("==", cid, flush=True)
            for line in one(cid, os.path.abspath(a.elm), home, a.v, a.js): print("  " + line.replace("\n", "\n  "), flush=True)
    finally:
        shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    main()
