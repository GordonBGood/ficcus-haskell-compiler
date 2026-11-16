#!/usr/bin/env python3
"""attach.py -- tests of the members attached to custom types (stage A1 of docs/ABILITIES-PROPOSAL.md, branch feat/attach).
Standard library only.  Needs `node` for the JS runs and gcc (clang if present) for the C runs.

  python3 tests/attach/attach.py --elm bin/elmficA2                 # all cases
  python3 tests/attach/attach.py --elm bin/elmficA2 --only dup-member,unknown-member

Each case is a directory cases/<id>/ with its sources (Main.elm, other modules), optional case.json
{"desc": "...", "main": "Main.elm", "deps": ["ficcus/money@1.0.0"]} and, for a RUN case, expected.out.
The expected results are the table expected.tsv (tab separated: id, outcome, error titles, text the output must contain):
  ACCEPT   `elm make` succeeds
  REJECT   `elm make` fails; the titles ("-- TITLE ----") are the third column, ';' separated
  RUN      ACCEPT, and the program (a Platform.worker that prints with Debug.log) gives expected.out when run as JavaScript
           (node) and as C (`--output=x.c`, gcc/clang); the third column says which: js, c or js+c
Packages of the cases (ficcus/*) live in packages/<author>/<name>/<version>/ and are entered in a private ELM_HOME (mkhome.py),
so nothing is downloaded and the real ELM_HOME is not touched.
Exit status 1 when any case differs from the table."""
import argparse, concurrent.futures as cf, difflib, json, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
def _find_root():
    # workspace root = the directory with targets/c and bin; works through the tests/attach symlink and from the repo
    for base in (HERE, os.path.dirname(os.path.realpath(__file__))):
        d = base
        while d != os.path.dirname(d):
            if os.path.isdir(os.path.join(d, "targets", "c")) and os.path.isdir(os.path.join(d, "bin")): return d
            d = os.path.dirname(d)
    return os.path.abspath(os.path.join(HERE, "..", ".."))
ROOT = _find_root()
SAFE = os.path.join(ROOT, "tools", "safe")
CASES = os.path.join(HERE, "cases")
TITLE_RE = re.compile(r"-- ([A-Z][A-Z0-9 '\-/]+?) -{10,}")
RT = os.path.join(ROOT, "targets", "c")
sys.path.insert(0, HERE)
import mkhome


def run(cmd, cwd, env, limit=120):
    env = dict(env, SAFE_TIMEOUT=str(limit))
    p = subprocess.run([SAFE] + cmd, cwd=cwd, env=env, capture_output=True, text=True, errors="replace")
    return p.returncode, p.stdout + p.stderr


def elm_json(deps):
    direct = {"elm/core": "1.0.5"}
    for d in deps:
        name, ver = d.split("@"); direct[name] = ver
    return {"type": "application", "source-directories": ["src"], "elm-version": "0.19.3",
            "dependencies": {"direct": direct, "indirect": {"elm/json": "1.1.3"}}, "test-dependencies": {"direct": {}, "indirect": {}}}


def titles(out):
    return TITLE_RE.findall(out)


def one(case, elm, home, want):
    src = os.path.join(CASES, case)
    meta = json.load(open(os.path.join(src, "case.json"))) if os.path.exists(os.path.join(src, "case.json")) else {}
    main = "src/" + meta.get("main", "Main.elm")
    work = tempfile.mkdtemp(prefix="attach-")
    try:
        dst = os.path.join(work, "p"); os.makedirs(dst)
        shutil.copytree(src, os.path.join(dst, "src"))          # sources in src/: the C path puts its overlay next to it
        if os.path.exists(os.path.join(src, "expected.out")): shutil.copy(os.path.join(src, "expected.out"), dst)
        json.dump(elm_json(meta.get("deps", [])), open(os.path.join(dst, "elm.json"), "w"))
        env = dict(os.environ, ELM_HOME=home)
        js = not (want[0] == "RUN" and "js" not in want[1].split("+"))     # a C-only RUN case is only checked, not generated as JavaScript
        rc, out = run([elm, "make", main, "--output=" + ("out.js" if js else "/dev/null")], dst, env)
        got_titles = titles(out)
        if "$$" in out or "$where" in out:
            return ("MANGLED", "a mangled name in the compiler output"), False, out
        if rc != 0:
            got = ("REJECT", ";".join(got_titles) if got_titles else "(exit %d: %s)" % (rc, out.strip()[-200:].replace("\n", " ")))
            ok = want[0] == "REJECT" and want[1] == got[1] and (not want[2] or want[2] in out)
            return got, ok, out
        if want[0] == "REJECT":
            return ("ACCEPT", ""), False, out
        if want[0] == "ACCEPT":
            return ("ACCEPT", ""), True, out
        # RUN
        exp = open(os.path.join(dst, "expected.out"), encoding="utf-8").read()
        problems = []
        kinds = want[1].split("+")
        if "js" in kinds:
            p = subprocess.run(["node", "-e", "require('./out.js').Elm.%s.init()" % os.path.splitext(os.path.basename(main))[0]], cwd=dst, capture_output=True, text=True, timeout=60)
            if p.stdout != exp or p.returncode != 0: problems.append("js: exit %d, output %r" % (p.returncode, (p.stdout + p.stderr)[:300]))
        if "c" in kinds:
            rc, cout = run([elm, "make", main, "--output=x.c", "--no-rc"], dst, env)
            if rc != 0: problems.append("c: compiler exit %d: %s" % (rc, cout.strip()[-300:]))
            else:
                for cc in ("gcc", "clang"):
                    if shutil.which(cc) is None: continue
                    exe = os.path.join(dst, "x_" + cc)
                    b = subprocess.run([cc, "-std=c99", "-pedantic", "-Wall", "-Wextra", "-Wno-unused-function", "-ffp-contract=off", "-O2", "-I", RT,
                                        os.path.join(dst, "x.c"), "-o", exe, "-lm"], capture_output=True, text=True)
                    if b.returncode != 0 or b.stderr: problems.append("c %s: %s" % (cc, b.stderr[-300:])); continue
                    r = subprocess.run([exe], capture_output=True, text=True)
                    if r.stdout != exp or r.returncode != 0: problems.append("c %s: exit %d, output %r" % (cc, r.returncode, (r.stdout + r.stderr)[:300]))
        return ("RUN", want[1]) if not problems else ("RUN-FAIL", "; ".join(problems)), not problems, out
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--only"); ap.add_argument("-j", type=int, default=2)
    ap.add_argument("-v", action="store_true", help="show the compiler output of failing cases")
    a = ap.parse_args()
    elm = os.path.abspath(a.elm)
    table = {}
    for line in open(os.path.join(HERE, "expected.tsv"), encoding="utf-8"):
        if line.startswith("#") or not line.strip(): continue
        f = line.rstrip("\n").split("\t") + ["", "", ""]
        table[f[0]] = (f[1], f[2], f[3])
    ids = sorted(os.listdir(CASES)) if not a.only else a.only.split(",")
    missing = [i for i in ids if i not in table]
    if missing: sys.exit("not in expected.tsv: " + ", ".join(missing))
    stale = [i for i in table if not os.path.isdir(os.path.join(CASES, i))]
    if stale and not a.only: sys.exit("in expected.tsv without a directory: " + ", ".join(stale))
    home = tempfile.mkdtemp(prefix="attach-home-")
    mkhome.make(home)
    bad = 0
    try:
        with cf.ThreadPoolExecutor(a.j) as ex:
            futs = {i: ex.submit(one, i, elm, home, table[i]) for i in ids}
            for i in ids:
                got, ok, out = futs[i].result()
                print("%-5s %-28s expected %s %-14s got %s %s" % ("ok" if ok else "FAIL", i, table[i][0], table[i][1], got[0], got[1]))
                if not ok:
                    bad += 1
                    if a.v: print("      " + out.strip().replace("\n", "\n      ")[:1500])
    finally:
        shutil.rmtree(home, ignore_errors=True)
    print("%d cases, %d differ from expected.tsv" % (len(ids), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
