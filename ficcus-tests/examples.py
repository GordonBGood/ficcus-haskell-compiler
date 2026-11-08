#!/usr/bin/env python3
"""Expected-file test of the small example projects (fib, poly, rec, init, marks).

For each ficcus-tests/<name>/ (elm.json, src/<Name>.fic) runs `elm make src/<Name>.fic --output=x.mono` in a copy,
which writes x.mono and x.types, and compares the project part of both (the package modules are left out; the `-- program` section of .mono is kept)
with ficcus-tests/expected/<name>.types and <name>.mono.

  python3 ficcus-tests/examples.py --elm bin/elmfic16 --safe tools/safe --elm-home H [--update] [--only rec,init]
Exit status 1 on any difference.
"""
import argparse, os, shutil, subprocess, sys, tempfile, difflib

HERE = os.path.dirname(os.path.abspath(__file__))
NAMES = ["fib", "poly", "rec", "init", "marks", "log"]
RUN = ["fib", "log"]      # also compiled to C (--output=x.c), built with gcc and clang and run: expected/<name>.out


def project_part(text, kind):
    out, skipping = [], False
    for line in text.split("\n"):
        if kind == "types" and line.startswith("-- package"): break
        if kind == "mono":                       # the package modules are left out, the program section stays
            if line.startswith("-- module ") and line.endswith("(package)"): skipping = True
            elif line.startswith("-- module ") or line.startswith("-- program"): skipping = False
            if skipping: continue
        out.append(line)
    return "\n".join(out).rstrip("\n") + "\n"


def run_c(a, dst, name, mod):
    """--output=x.c, build with gcc and clang (the flags of targets/suite.json), run, compare with expected/<name>.out"""
    env = dict(os.environ, ELM_HOME=a.elm_home)
    p = subprocess.run([a.safe, a.elm, "make", "src/" + mod, "--output=x.c"], cwd=dst, env=env, capture_output=True)
    if p.returncode != 0:
        print("FAIL %s.c: compiler exit %d\n%s" % (name, p.returncode, (p.stdout + p.stderr).decode()[-400:])); return 1
    want = open(os.path.join(HERE, "expected", name + ".out"), encoding="utf-8").read()
    rt = os.path.join(HERE, "..", "..", "targets", "c")
    bad = 0
    for cc in ("gcc", "clang"):
        if shutil.which(cc) is None: continue
        exe = os.path.join(dst, "x_" + cc)
        b = subprocess.run([cc, "-std=c99", "-pedantic", "-Wall", "-Wextra", "-Wno-unused-function", "-ffp-contract=off", "-O2",
                            "-I", rt, os.path.join(dst, "x.c"), "-o", exe, "-lm"], capture_output=True)
        if b.returncode != 0 or b.stderr:
            print("FAIL %s.c %s: %s" % (name, cc, b.stderr.decode()[-300:])); bad += 1; continue
        r = subprocess.run([exe], capture_output=True)
        got = r.stdout.decode("utf-8", "replace")
        if r.returncode != 0 or got != want:
            print("FAIL %s.c %s: exit %d, output differs" % (name, cc, r.returncode))
            sys.stdout.writelines(list(difflib.unified_diff(want.splitlines(True), got.splitlines(True), "expected", "got"))[:20]); bad += 1
        else: print("ok   %s.c (%s)" % (name, cc))
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--safe", required=True); ap.add_argument("--elm-home", required=True)
    ap.add_argument("--update", action="store_true"); ap.add_argument("--only")
    a = ap.parse_args()
    bad = 0
    for name in (a.only.split(",") if a.only else NAMES):
        src = os.path.join(HERE, name)
        mod = [f for f in os.listdir(os.path.join(src, "src")) if f.endswith(".fic")][0]
        work = tempfile.mkdtemp()
        dst = os.path.join(work, name)
        shutil.copytree(src, dst, ignore=shutil.ignore_patterns("elm-stuff"))
        p = subprocess.run([a.safe, a.elm, "make", "src/" + mod, "--output=x.mono"], cwd=dst,
                           env=dict(os.environ, ELM_HOME=a.elm_home), capture_output=True)
        if p.returncode != 0:
            print("FAIL %s: compiler exit %d\n%s" % (name, p.returncode, (p.stdout + p.stderr).decode()[-400:])); bad += 1; continue
        for kind in ("types", "mono"):
            got = project_part(open(os.path.join(dst, "x." + kind), encoding="utf-8").read(), kind)
            path = os.path.join(HERE, "expected", name + "." + kind)
            if a.update:
                open(path, "w", encoding="utf-8").write(got); print("updated", path); continue
            want = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
            if got == want: print("ok   %s.%s" % (name, kind))
            else:
                bad += 1; print("DIFF %s.%s" % (name, kind))
                sys.stdout.writelines(list(difflib.unified_diff(want.splitlines(True), got.splitlines(True), "expected", "got"))[:40])
        if name in RUN and not a.update:
            bad += run_c(a, dst, name, mod)
        shutil.rmtree(work, ignore_errors=True)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
