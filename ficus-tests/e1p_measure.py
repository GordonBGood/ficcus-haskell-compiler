#!/usr/bin/env python3
"""E1p design note (docs/E1P-DESIGN.md): the copies of a model that `update` hands to a helper. Programs in ficus-tests/e1p/src/*.fic,
Elm 0.19.3 goldens in expected/e1p_*.out (made from e1p/ref/src/*Ref.elm, where `init` folds `update` 1000 times, as G17bRef does).

  H1Helper      update passes m to a helper `{ m | a = Array.set .. m.a, n = .. }` (the record update temporary and a later m.n hold m.a)
  H2HelperFull  the helper rebuilds every field `{ a = Array.set .. m.a, d = m.d, n = .. }` (a later m.d, m.n hold m.a)
  H3CallerLive  update passes m whole to the helper and still reads m.d and m.n afterwards (a Dup of all of m, a included)
  H4TwoLevel    a helper passes `{ m | n = .. }` to a second helper that writes m.a
  H5Nested      `let i = m.inner in { m | inner = { i | a = Array.set .. i.a, k = .. } }` inside update itself (ModelUnpack does not reach i)
  H6DictUpd     helper `{ m | d = Dict.insert .. m.d, n = .. }`: owned (the let), reuse misses instead of copies
  H6DictFull    helper `{ a = m.a, d = Dict.insert .. m.d, n = .. }`: the parameter is BORROWED (a Borrow gap, not a split gap)
  H7Closure     `update = updateWith 2` (the closure fallback) with the H1 body
  X1, X3, X5, X7  the same programs split by hand with record patterns (`setA { a, d, n } = ..`): what the split should reach

Each program runs 1000 steps of the typed stepper (-DFIC_STEP_TEST=1000), gcc -O2 and ASan + UBSan (no pool). Pass: output = Elm,
live 0, no sanitizer report. With --targets the H programs also fail above their target after E1p (the X programs are at it today).
  python3 ficus-tests/e1p_measure.py --elm bin/elmficNN --elm-home H [--targets] [--only H1Helper,..] [--goldens bin/elm0193]
--goldens ELM: (re)make the goldens with Elm 0.19.3 under node first."""
import argparse, os, re, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
RT = os.path.join(HERE, "..", "..", "targets", "c")
SAN = ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-g", "-DFIC_NO_POOL", "-Wno-maybe-uninitialized"]
N = 1000
# (program, model copies at elmficG70a, target model copies after E1p, target reuse misses after E1p or None)
PROGRAMS = [("H1Helper", 1960, 5, 5), ("H2HelperFull", 1960, 5, 5), ("H3CallerLive", 1960, 5, 5), ("H4TwoLevel", 1960, 5, 5),
            ("H5Nested", 1960, 5, 5), ("H6DictUpd", 0, 0, 5), ("H6DictFull", 0, 0, None), ("H7Closure", 1960, 5, 5),
            ("X1Helper", 5, 5, 5), ("X3CallerLive", 5, 5, 5), ("X5Nested", 5, 5, 5), ("X7Closure", 5, 5, 5)]


def goldens(elm, home, only):
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    d = os.path.join(tmp, "ref"); shutil.copytree(os.path.join(HERE, "e1p", "ref"), d, ignore=shutil.ignore_patterns("elm-stuff"))
    for mod, *_ in PROGRAMS:
        if only and mod not in only: continue
        js = os.path.join(tmp, mod + ".js")
        p = subprocess.run([os.path.abspath(elm), "make", "src/%sRef.elm" % mod, "--output=" + js], cwd=d, capture_output=True, env=dict(os.environ, ELM_HOME=home))
        if p.returncode != 0: sys.exit("elm: " + (p.stdout + p.stderr).decode()[-300:])
        with open(js, "a") as f: f.write("\nthis.Elm.%sRef.init();\n" % mod)
        out = subprocess.run(["node", js], capture_output=True).stdout          # Debug.log goes to stdout; the DEV banner to stderr
        open(os.path.join(HERE, "expected", "e1p_%s.out" % mod.lower()), "wb").write(out)
    shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--elm-home", required=True)
    ap.add_argument("--targets", action="store_true"); ap.add_argument("--only", default=""); ap.add_argument("--goldens")
    a = ap.parse_args()
    only = set(x for x in a.only.split(",") if x)
    if a.goldens: goldens(a.goldens, a.elm_home, only)
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    d = os.path.join(tmp, "e1p"); shutil.copytree(os.path.join(HERE, "e1p"), d, ignore=shutil.ignore_patterns("elm-stuff", "ref"))
    bad = 0
    for mod, now, target, miss in PROGRAMS:
        if only and mod not in only: continue
        want = open(os.path.join(HERE, "expected", "e1p_%s.out" % mod.lower())).read()
        c = os.path.join(tmp, mod + ".c")
        p = subprocess.run([os.path.abspath(a.elm), "make", "src/%s.fic" % mod, "--output=" + c, "--rc"], cwd=d, capture_output=True,
                           env=dict(os.environ, ELM_HOME=a.elm_home))
        if p.returncode != 0:
            print("FAIL %s compiles  %s" % (mod, (p.stdout + p.stderr).decode()[-300:])); bad += 1; continue
        for tag, cf in (("O2", ["-O2"]), ("san", SAN)):
            exe = os.path.join(tmp, mod + "_" + tag)
            b = subprocess.run(["gcc", "-std=c99", "-ffp-contract=off", "-w", *cf, "-DFIC_STATS", "-DFIC_STEP_TEST=%d" % N, "-I", RT, c,
                                "-o", exe, "-lm"], capture_output=True)
            if b.returncode != 0:
                print("FAIL %s %s gcc  %s" % (mod, tag, b.stderr.decode()[-300:])); bad += 1; continue
            r = subprocess.run([exe], capture_output=True)
            e = r.stderr.decode()
            m = re.search(r"FIC_STATS model: steps (\d+) inplace (\d+) copied (\d+) vec_copy (\d+) reuse_miss (\d+) model_copies (\d+)", e)
            copies, misses = (int(m.group(6)), int(m.group(5))) if m else (-1, -1)
            ok = r.returncode == 0 and r.stdout.decode() == want and " live 0 " in e and m is not None and int(m.group(1)) == N
            over = a.targets and (copies > target or (miss is not None and misses > miss))
            print(("ok   " if ok and not over else "FAIL ") + "%s %s: output = Elm, live 0, model copies %d, reuse misses %d (G70a copies %d; target %d copies%s)"
                  % (mod, tag, copies, misses, now, target, "" if miss is None else ", %d misses" % miss)
                  + ("" if ok else "  " + (r.stdout.decode() + e)[-300:]))
            bad += 0 if ok and not over else 1
    shutil.rmtree(tmp, ignore_errors=True)
    print("e1p_measure: %s" % ("%d failures" % bad if bad else "all ok"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
