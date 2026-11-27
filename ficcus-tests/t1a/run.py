#!/usr/bin/env python3
"""T1a-1 (docs/attach/T1A-NOTES.md): the Concurrent module on the E2 scheduler.

Elm has no equivalent, so the expected outputs (expected/<name>.out) are reasoned by hand from the rules R1 to R8 of the notes, section 3.
Each program is compiled --rc (gcc -O2; ASan + UBSan without the pool; -O1 -DFIC_DROP_ALL) and --no-rc (-O2); stdout must equal the
expected file; under --rc FIC_STATS must say live 0 and the `FIC_STATS concurrent:` line must equal expected/stats.txt.
Seeded shuffle (FIC_SCHED_SEED, T1-D14): for the programs in SHUFFLE, seeds 1..30 on the -O2 build: the same multiset of lines and the
same last line as the deterministic run, each sender's order kept (FILTERS), the same seed twice gives the same output, and at least two
different orders are seen (programs marked so); seeds 1..4 also on the sanitizer build with live 0.
Identity (T1-D12): the C text of programs that do not use Concurrent (effects3/src, e2review/src; a3b_identity.py --more covers the
suite, effects, effects2 and e1p) equals the reference binary's, --rc and --no-rc.

  python3 ficcus-tests/t1a/run.py --elm B --ref bin/elmficP1b --elm-home H [--only a,b] [--no-identity]"""
import argparse, collections, glob, os, re, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
TESTS_DIR = os.path.dirname(HERE)
RT = os.path.join(TESTS_DIR, "..", "..", "targets", "c")
SAN = ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-g", "-DFIC_NO_POOL"]
ENV = {"FIC_TIME": "1700000000000", "TZ": "UTC"}
NAMES = ["T1aOrder", "T1aMailbox", "T1aKill", "T1aFailed", "T1aDeadlock", "T1aMany"]
# name: (must see at least two orders over the seeds, the last line is the same in every order)
SHUFFLE = {"T1aOrder": (True, True), "T1aMailbox": (True, True), "T1aKill": (True, True), "T1aFailed": (False, True), "T1aDeadlock": (False, False)}
FILTERS = {"T1aMailbox": [r"^got: Num ", r"^got: Word "]}
IDENTITY_DIRS = ["effects3", "e2review"]


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, **kw)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--ref"); ap.add_argument("--elm-home", required=True)
    ap.add_argument("--only"); ap.add_argument("--no-identity", action="store_true")
    a = ap.parse_args()
    names = [n for n in NAMES if not a.only or n in a.only.split(",")]
    stats = dict(l.split(" ", 1) for l in open(os.path.join(HERE, "expected", "stats.txt")).read().splitlines() if l.strip())
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    proj = os.path.join(tmp, "t1a"); os.makedirs(proj)
    shutil.copy(os.path.join(HERE, "elm.json"), proj); shutil.copytree(os.path.join(HERE, "src"), os.path.join(proj, "src"))
    bad = 0

    def report(ok, what, detail=""):
        nonlocal bad
        print(("ok   " if ok else "FAIL ") + what + ("" if ok else "  " + detail)); bad += 0 if ok else 1

    def build(c, exe, cf):
        b = run(["gcc", "-std=c99", "-ffp-contract=off", "-w", *cf, "-DFIC_STATS", "-I", RT, c, "-o", exe, "-lm"])
        return b.returncode == 0, b.stderr.decode()[-300:]

    def execute(exe, extra=None):
        r = run([exe], env=dict(os.environ, **ENV, **(extra or {})), timeout=600)
        return r.returncode, r.stdout.decode(), r.stderr.decode()

    for n in names:
        want = open(os.path.join(HERE, "expected", n + ".out")).read()
        for flag in ("--rc", "--no-rc"):
            c = os.path.join(tmp, n + flag + ".c")
            p = run([os.path.abspath(a.elm), "make", "src/%s.fic" % n, "--output=" + c, flag], cwd=proj, env=dict(os.environ, ELM_HOME=a.elm_home))
            if p.returncode != 0:
                report(False, "%s %s compiles" % (n, flag), (p.stdout + p.stderr).decode()[-400:]); continue
            report("#error \"internal: Concurrent" not in open(c).read(), "%s %s: the scheduler patch applied" % (n, flag))
            for tag, cf in ((("O2", ["-O2"]), ("san", SAN), ("dropall", ["-O1", "-DFIC_DROP_ALL"])) if flag == "--rc" else (("O2", ["-O2"]),)):
                exe = os.path.join(tmp, n + flag + tag)
                ok, err = build(c, exe, cf)
                if not ok:
                    report(False, "%s %s %s builds" % (n, flag, tag), err); continue
                code, out, err = execute(exe)
                ok = code == 0 and out == want
                if flag == "--rc":
                    live = re.search(r"FIC_STATS: allocs \d+ live (\d+)", err)
                    st = re.search(r"FIC_STATS concurrent: (.*)", err)
                    ok = ok and live is not None and live.group(1) == "0" and st is not None and st.group(1) == stats[n]
                if tag == "dropall": ok = ok and re.search(r"FIC_DROP_ALL: \d+ objects checked, 0 bad, 0 live after the free", err) is not None
                report(ok, "%s %s %s: output = expected%s" % (n, flag, tag, ", live 0, stats" if flag == "--rc" else ""),
                       "exit %d\n--- got\n%s\n--- stderr\n%s" % (code, out[-600:], err[-600:]))
                if flag == "--rc" and tag in ("O2", "san") and n in SHUFFLE:
                    seeds = range(1, 31) if tag == "O2" else range(1, 5)
                    outs = {}
                    ok = True; why = ""
                    for s in seeds:
                        code, out, err = execute(exe, {"FIC_SCHED_SEED": str(s)})
                        outs[s] = out
                        lines, wl = out.splitlines(), want.splitlines()
                        if code != 0 or collections.Counter(lines) != collections.Counter(wl) or (SHUFFLE[n][1] and lines[-1:] != wl[-1:]):
                            ok = False; why = "seed %d: exit %d\n%s" % (s, code, out[-600:]); break
                        for f in FILTERS.get(n, []):
                            if [l for l in lines if re.search(f, l)] != [l for l in wl if re.search(f, l)]:
                                ok = False; why = "seed %d: the order of %s" % (s, f); break
                        if tag == "san":
                            live = re.search(r"FIC_STATS: allocs \d+ live (\d+)", err)
                            if live is None or live.group(1) != "0": ok = False; why = "seed %d: live %s" % (s, live.group(1) if live else "?")
                        if not ok: break
                    if ok and tag == "O2":
                        again = execute(exe, {"FIC_SCHED_SEED": "7"})[1]
                        ok = again == outs[7]; why = "seed 7 twice differs"
                        if ok and SHUFFLE[n][0]:
                            ok = len(set(outs.values())) >= 2; why = "one order only over 30 seeds"
                    report(ok, "%s --rc %s: shuffle seeds %d..%d (multiset, last line, sender order%s)" % (
                        n, tag, seeds[0], seeds[-1], ", reproducible, %d orders" % len(set(outs.values())) if tag == "O2" else ", live 0"), why)

    if not a.no_identity and a.ref:
        same = diff = 0
        for d in IDENTITY_DIRS:
            pd = os.path.join(tmp, "id-" + d); shutil.copytree(os.path.join(TESTS_DIR, d), pd, ignore=shutil.ignore_patterns("elm-stuff"))
            for f in sorted(glob.glob(os.path.join(pd, "src", "*.fic"))):
                m = os.path.basename(f)
                for flag in ("--rc", "--no-rc"):
                    texts = []
                    for b in (a.ref, a.elm):
                        o = os.path.join(tmp, "id.c")
                        if os.path.exists(o): os.remove(o)
                        p = run([os.path.abspath(b), "make", "src/" + m, "--output=" + o, flag], cwd=pd, env=dict(os.environ, ELM_HOME=a.elm_home))
                        texts.append(open(o).read() if p.returncode == 0 and os.path.exists(o) else "COMPILE FAILED " + (p.stdout + p.stderr).decode()[-200:])
                    if texts[0] == texts[1] and not texts[0].startswith("COMPILE FAILED"): same += 1
                    elif texts[0] == texts[1]: same += 1; print("note %s/%s %s: both refuse (same message)" % (d, m, flag))
                    else: diff += 1; print("DIFF %s/%s %s" % (d, m, flag))
        report(diff == 0, "identity vs %s: %d C texts identical, %d differ (%s)" % (os.path.basename(a.ref), same, diff, ", ".join(IDENTITY_DIRS)))
    shutil.rmtree(tmp, ignore_errors=True)
    print("t1a: %s" % ("%d failures" % bad if bad else "all ok"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
