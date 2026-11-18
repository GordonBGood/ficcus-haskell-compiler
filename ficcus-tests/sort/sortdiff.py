#!/usr/bin/env python3
"""sortdiff.py (H21): ficcus-tests/sort/src/Main.fic under Elm 0.19.3 (JS, node, stand-in Vector) is the reference; the C output built from it
(--rc and --no-rc; plain, and ASan+UBSan with FIC_NO_POOL) must print the same line. Usage:
  python3 ficcus-tests/sort/sortdiff.py --elm bin/elmficS1 --ref bin/elm0193 --elm-home H [--work DIR] [--modes rc,norc,rcsan]"""
import argparse, os, shutil, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__)); R = os.path.dirname(os.path.dirname(HERE)); W = os.path.dirname(R)
ap = argparse.ArgumentParser()
ap.add_argument("--elm", required=True); ap.add_argument("--ref", required=True); ap.add_argument("--elm-home", required=True)
ap.add_argument("--work", default=os.path.join(os.environ.get("CLAUDE_CODE_TMPDIR", "/tmp"), "sortdiff")); ap.add_argument("--modes", default="rc,norc,rcsan")
a = ap.parse_args()
elm, ref = os.path.abspath(a.elm), os.path.abspath(a.ref)
env = dict(os.environ, ELM_HOME=os.path.abspath(a.elm_home))
w = os.path.abspath(a.work); shutil.rmtree(w, ignore_errors=True); os.makedirs(w + "/src")
shim = os.path.join(R, "ficcus-tests", "vecshim")
src = open(os.path.join(HERE, "src", "Main.fic")).read()
open(w + "/src/Main.elm", "w").write(src)
open(w + "/elm.json", "w").write('{"type":"application","source-directories":["src","%s"],"elm-version":"0.19.3","dependencies":{"direct":{"elm/core":"1.0.5","elm/json":"1.1.3"},"indirect":{}},"test-dependencies":{"direct":{},"indirect":{}}}' % shim)
def run(cmd, **k):
    return subprocess.run(cmd, cwd=w, env=env, capture_output=True, text=True, **k)
r = run([ref, "make", "src/Main.elm", "--output=ref.js"])
if r.returncode: sys.exit("reference compile failed:\n" + r.stdout + r.stderr)
open(w + "/run.js", "w").write("global.console.log=function(){};var l=console.error;var o=process.stdout.write.bind(process.stdout);\nvar log=console.log;")
open(w + "/run.js", "w").write("var o=[];var orig=console.log;console.log=function(s){o.push(s)};var m=require('./ref.js');m.Elm.Main.init();console.log=orig;console.log(o.join('\\n'));")
r = run(["node", "run.js"]); refout = r.stdout.strip()
if not refout.startswith("sortdiff:"): sys.exit("reference run failed:\n" + r.stdout[:500] + r.stderr[:500])
print("reference: %d lines" % refout.count("\\n"))
open(w + "/e/elm.json" if False else w + "/elmc.json", "w").write("")
os.makedirs(w + "/c/src"); shutil.copy(w + "/src/Main.elm", w + "/c/src/Main.fic")
open(w + "/c/elm.json", "w").write(open(w + "/elm.json").read().replace(',"%s"' % shim, '').replace('"direct":{"elm/core":"1.0.5","elm/json":"1.1.3"}', '"direct":{"elm/core":"1.0.5","elm/json":"1.1.3"}'))
bad = 0
for mode in a.modes.split(","):
    flags = ["--rc"] if mode.startswith("rc") else []
    r = subprocess.run([elm, "make", "src/Main.fic", "--output=x.c"] + flags, cwd=w + "/c", env=env, capture_output=True, text=True)
    if r.returncode: print("FAIL compile", mode, r.stdout[-600:], r.stderr[-600:]); bad += 1; continue
    cc = ["gcc", "-std=c99", "-O1", "-ffp-contract=off", "-w", "-I", os.path.join(W, "targets", "c"), "x.c", "-o", "x", "-lm"]
    if mode.endswith("san"): cc[1:1] = ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-g", "-DFIC_NO_POOL"]
    if flags: cc[1:1] = ["-DFIC_STATS"]
    r = subprocess.run(cc, cwd=w + "/c", capture_output=True, text=True)
    if r.returncode: print("FAIL cc", mode, r.stderr[-600:]); bad += 1; continue
    r = subprocess.run(["./x"], cwd=w + "/c", capture_output=True, text=True)
    out = [l for l in r.stderr.splitlines() + r.stdout.splitlines() if l.startswith("sortdiff:")]
    live = [l for l in r.stderr.splitlines() if l.startswith("FIC_STATS")]
    ok = out and out[0] == refout and r.returncode == 0
    print(("ok  " if ok else "FAIL"), mode, "exit", r.returncode, live[0][:60] if live else "")
    if not ok:
        bad += 1
        if out:
            for x, y in zip(out[0].split("\\n"), refout.split("\\n")):
                if x != y: print("  C  ", x, "\n  JS ", y); break
        else: print(r.stderr[-500:])
sys.exit(1 if bad else 0)
