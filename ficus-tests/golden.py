#!/usr/bin/env python3
"""The Elm 0.19.3 golden of a ficus-tests/knownNN program: its .fic source is built as an .elm module with bin/elm0193 and run under node;
the Debug.log lines (console.log) are the expected output (`expected/<name>.out`).

  python3 ficus-tests/golden.py NAME [--elm0193 bin/elm0193] [--elm-home H] [--write]"""
import argparse, os, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
NODE = os.environ.get("NODE", "/home/gordon/.local/node-linux-x64/bin/node")

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("name"); ap.add_argument("--elm0193", default=os.path.join(ROOT, "bin", "elm0193"))
    ap.add_argument("--elm-home", default=os.path.expanduser("~/.elm")); ap.add_argument("--write", action="store_true")
    a = ap.parse_args()
    src = os.path.join(HERE, a.name)
    mod = sorted(f for f in os.listdir(os.path.join(src, "src")) if f.endswith(".fic"))[0][:-4]
    d = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    try:
        shutil.copytree(src, os.path.join(d, "p"), ignore=shutil.ignore_patterns("elm-stuff")); p = os.path.join(d, "p")
        shutil.copy(os.path.join(p, "src", mod + ".fic"), os.path.join(p, "src", mod + ".elm"))
        env = dict(os.environ, ELM_HOME=a.elm_home)
        r = subprocess.run([a.elm0193, "make", "src/" + mod + ".elm", "--output=o.js"], cwd=p, env=env, capture_output=True)
        if r.returncode != 0: print(r.stderr.decode()[-2000:]); return 1
        js = "var E=require('./o.js'); E.Elm.%s.init();" % mod
        r = subprocess.run([NODE, "-e", js], cwd=p, capture_output=True)
        out = r.stdout.decode("utf-8")
        if r.returncode != 0: print(r.stderr.decode()[-2000:]); return 1
        if a.write: open(os.path.join(HERE, "expected", a.name + ".out"), "w", encoding="utf-8").write(out)
        else: sys.stdout.write(out)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    return 0

if __name__ == "__main__":
    sys.exit(main())
