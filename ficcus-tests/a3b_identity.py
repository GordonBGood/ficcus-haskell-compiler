#!/usr/bin/env python3
"""A3b identity (docs/A3B-PLAN.md section 5): programs without a member inside a container must give byte identical C.

  python3 ficcus-tests/a3b_identity.py --elm bin/elmficA3b --ref bin/elmficA4b --elm-home H [--more]

Programs: the 16 of ficcus-tests/runall/suite.json (13 distinct sources); with --more also ficcus-tests/{e1p,effects,effects2}/src/*.fic.
Each is compiled with --rc and with --no-rc by both binaries, each compile in a fresh copy of the program's project (no elm-stuff shared).
Prints one line per program and mode; exit 1 when any C text differs."""
import argparse, glob, json, os, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))


def programs(more):
    suite = json.load(open(os.path.join(HERE, "runall", "suite.json")))
    seen, out = set(), []
    for t in suite["tests"]:
        src = os.path.normpath(os.path.join(HERE, "runall", t["fic"]))
        if src not in seen: seen.add(src); out.append((t["name"], src))
    if more:
        for d in ("e1p", "effects", "effects2"):
            out += [(os.path.basename(f)[:-4], f) for f in sorted(glob.glob(os.path.join(HERE, d, "src", "*.fic")))]
    return out


def project_of(src):
    d = os.path.dirname(src)
    while not os.path.exists(os.path.join(d, "elm.json")) and d != "/":
        d = os.path.dirname(d)
    return d


def compile_c(elm, src, mode, home):
    proj = project_of(src)
    work = tempfile.mkdtemp(prefix="a3bid-")
    try:
        dst = os.path.join(work, "p")
        shutil.copytree(proj, dst, ignore=shutil.ignore_patterns("elm-stuff", "*.c", "*.js", "*.o"))
        out = os.path.join(work, "x.c")
        p = subprocess.run([elm, "make", os.path.relpath(src, proj), "--output=" + out, mode], cwd=dst,
                           env=dict(os.environ, ELM_HOME=home), capture_output=True, text=True, timeout=600)
        if p.returncode != 0: return None, (p.stdout + p.stderr)[-400:]
        return open(out, encoding="utf-8", errors="replace").read(), ""
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--ref", required=True); ap.add_argument("--elm-home", required=True)
    ap.add_argument("--more", action="store_true")
    a = ap.parse_args()
    elm, ref = os.path.abspath(a.elm), os.path.abspath(a.ref)
    bad = n = 0
    for name, src in programs(a.more):
        for mode in ("--no-rc", "--rc"):
            x, ex = compile_c(elm, src, mode, a.elm_home)
            y, ey = compile_c(ref, src, mode, a.elm_home)
            n += 1
            if x is None or y is None:
                print("ERROR     %-28s %s  %s" % (name, mode, ex or ey)); bad += 1
            elif x != y:
                print("DIFFERENT %-28s %s" % (name, mode)); bad += 1
            else:
                print("identical %-28s %s" % (name, mode))
    print("%d compiles compared, %d differ" % (n, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
