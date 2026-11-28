#!/usr/bin/env python3
"""E1p review (docs/E1P-REVIEW.md): five programs in ficus-tests/e1pr/src, each a one-shot worker whose `init` folds a step
function 1000 (R13: 300000) times by a self tail call and prints the result with Debug.log. Goldens in expected/e1pr_*.out
(Elm 0.19.3 under node, made from the same source with --goldens).

  E1pR1Name         a record field named `f0` beside a field the split does not read (fixed: split variables named by position)
  E1pR10Alias       negative: `let old = m` read by field after `setA m`: exactly 1960 copies (fewer = an unsound in-place write)
  E1pR11Capture     negative: closures capture m and an alias of m, then a helper writes m.a: exactly 1960 copies
  E1pR13TailBranch  positive: m rebuilt / returned whole / passed to a writing helper / wrapped in a nested record per branch;
                    300000 tail-recursive steps (constant stack): at most 5 copies
  E1pR14LambdaSet   TARGET: a field read under a lambda captures the whole struct, the leaf written beside it copies
                    (1960 today, also on elmficG70a): at most 5 copies

Each program: --rc, gcc -O2 and ASan+UBSan (-DFIC_NO_POOL), output = Elm, live 0, and the `copied` counter of the global FIC_STATS
line checked against the expectation. TARGET rows print TARGET instead of FAIL and do not count as failures unless --strict.
  python3 ficus-tests/e1p_review.py --elm bin/elmficNN --elm-home H [--strict] [--only E1pR1Name,..] [--goldens bin/elm0193]"""
import argparse, os, re, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
RT = os.path.join(HERE, "..", "..", "targets", "c")
SAN = ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-g", "-DFIC_NO_POOL", "-Wno-maybe-uninitialized"]
# (program, copies: ("=", n) exact or ("<=", n) at most, target: True when it fails today and is a fix target)
PROGRAMS = [("E1pR1Name", ("<=", 0), False), ("E1pR10Alias", ("=", 1960), False), ("E1pR11Capture", ("=", 1960), False),
            ("E1pR13TailBranch", ("<=", 5), False), ("E1pR14LambdaSet", ("<=", 5), True)]


def goldens(elm, home, only):
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    for mod, _, _ in PROGRAMS:
        if only and mod not in only: continue
        d = os.path.join(tmp, mod); os.makedirs(os.path.join(d, "src"))
        shutil.copy(os.path.join(HERE, "e1pr", "elm.json"), d)
        shutil.copy(os.path.join(HERE, "e1pr", "src", mod + ".fic"), os.path.join(d, "src", mod + ".elm"))
        js = os.path.join(tmp, mod + ".js")
        p = subprocess.run([os.path.abspath(elm), "make", "src/%s.elm" % mod, "--output=" + js], cwd=d, capture_output=True, env=dict(os.environ, ELM_HOME=home))
        if p.returncode != 0: sys.exit("elm: " + (p.stdout + p.stderr).decode()[-300:])
        with open(js, "a") as f: f.write("\nthis.Elm.%s.init();\n" % mod)
        out = subprocess.run(["node", js], capture_output=True).stdout          # Debug.log goes to stdout
        open(os.path.join(HERE, "expected", "e1pr_%s.out" % mod.lower()), "wb").write(out)
    shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--elm-home", required=True)
    ap.add_argument("--strict", action="store_true"); ap.add_argument("--only", default=""); ap.add_argument("--goldens")
    a = ap.parse_args()
    only = set(x for x in a.only.split(",") if x)
    if a.goldens: goldens(a.goldens, a.elm_home, only)
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    d = os.path.join(tmp, "e1pr"); shutil.copytree(os.path.join(HERE, "e1pr"), d, ignore=shutil.ignore_patterns("elm-stuff"))
    bad = targets = 0
    for mod, (op, n), target in PROGRAMS:
        if only and mod not in only: continue
        fail = "TARGET" if target and not a.strict else "FAIL  "
        want = open(os.path.join(HERE, "expected", "e1pr_%s.out" % mod.lower())).read()
        c = os.path.join(tmp, mod + ".c")
        p = subprocess.run([os.path.abspath(a.elm), "make", "src/%s.fic" % mod, "--output=" + c, "--rc"], cwd=d, capture_output=True,
                           env=dict(os.environ, ELM_HOME=a.elm_home))
        if p.returncode != 0:
            print("%s %s compiles  %s" % (fail, mod, (p.stdout + p.stderr).decode().strip()[-200:].replace("\n", " ")))
            if fail == "TARGET": targets += 1
            else: bad += 1
            continue
        for tag, cf in (("O2", ["-O2"]), ("san", SAN)):
            exe = os.path.join(tmp, mod + "_" + tag)
            b = subprocess.run(["gcc", "-std=c99", "-ffp-contract=off", "-w", *cf, "-DFIC_STATS", "-I", RT, c, "-o", exe, "-lm"], capture_output=True)
            if b.returncode != 0:
                print("%s %s %s gcc  %s" % (fail, mod, tag, b.stderr.decode()[-200:].replace("\n", " ")))
                if fail == "TARGET": targets += 1
                else: bad += 1
                continue
            r = subprocess.run([exe], capture_output=True)
            e = r.stderr.decode()
            m = re.search(r"FIC_STATS: .* live (\d+) .* copied (\d+) ", e)
            copies = int(m.group(2)) if m else -1
            ok = r.returncode == 0 and r.stdout.decode() == want and m is not None and m.group(1) == "0"
            within = copies == n if op == "=" else 0 <= copies <= n
            status = "ok    " if ok and within else ("FAIL  " if not ok else fail)
            print("%s %s %s: output %s Elm, live %s, copies %d (expected %s %d)" % (status, mod, tag, "=" if ok else "/=",
                  m.group(1) if m else "?", copies, op, n) + ("" if ok else "  " + (r.stdout.decode() + e)[-300:]))
            if status == "TARGET": targets += 1
            elif status != "ok    ": bad += 1
    shutil.rmtree(tmp, ignore_errors=True)
    print("e1p_review: %s%s" % ("%d failures" % bad if bad else "all ok", ", %d target rows" % targets if targets else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
