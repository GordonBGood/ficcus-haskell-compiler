#!/usr/bin/env python3
"""Expected-file test of the small example projects (fib, poly, rec, init, marks).

For each ficcus-tests/<name>/ (elm.json, src/<Name>.fic) runs `elm make src/<Name>.fic --output=x.mono` in a copy,
which writes x.mono and x.types, and compares the project part of both (everything before the first package module)
with ficcus-tests/expected/<name>.types and <name>.mono.

  python3 ficcus-tests/examples.py --elm bin/elmfic16 --safe tools/safe --elm-home H [--update] [--only rec,init]
Exit status 1 on any difference.
"""
import argparse, os, shutil, subprocess, sys, tempfile, difflib

HERE = os.path.dirname(os.path.abspath(__file__))
NAMES = ["fib", "poly", "rec", "init", "marks"]


def project_part(text, kind):
    out = []
    for line in text.split("\n"):
        if kind == "types" and line.startswith("-- package"): break
        if kind == "mono" and line.startswith("-- module ") and line.endswith("(package)"): break
        out.append(line)
    return "\n".join(out).rstrip("\n") + "\n"


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
        shutil.rmtree(work, ignore_errors=True)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
