#!/usr/bin/env python3
"""Effects slice E2 (docs/EFFECTS-CHECK.md steps 4 to 8): programs in ficcus-tests/effects2/src/*.fic, compared with Elm 0.19.3.

Each program is its own Elm reference: --goldens copies it to a scratch Elm project as a .elm file, compiles it with the reference
compiler and runs it under node with effects2/ref/run.js (Debug.log lines, and outgoing port messages as `<port>: <JSON>`); the output
is expected/e2_<name>.out. A check compiles the program --rc (gcc -O2, and ASan + UBSan without the pool) and --no-rc (-O2), runs it
and compares stdout byte for byte; under --rc the FIC_STATS line must say live 0 (the effect state is released at the end, step 8).
A table entry can add an environment (FIC_TIME, FIC_SEED, FIC_PORTS_IN), compare by a filter (lines whose values depend on the clock),
and a model copy target (FIC_STATS model line, G17).

  python3 ficcus-tests/effects_e2.py --elm bin/elmficNN --elm-home H [--only a,b]          exit 1 on any failure
  python3 ficcus-tests/effects_e2.py --goldens --ref bin/elm0193 --elm-home H [--only a,b]  writes expected/e2_*.out"""
import argparse, os, re, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
RT = os.path.join(HERE, "..", "..", "targets", "c")
SAN = ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-g", "-DFIC_NO_POOL", "-Wno-maybe-uninitialized"]

# the clock of the tests with timers: the C program's FIC_TIME (a virtual clock, no waiting), and the zone on both sides
T = {"FIC_TIME": "1700000000000", "TZ": "UTC"}
# name: (environment, model copies wanted (None: not checked), filter of the output or None, what it tests)
TESTS = {
    "S2Perform": ({}, None, None, "E1 (d): Task.perform in update, no message ever comes"),
    "E2Perform": ({}, None, None, "E1 (d): Task.perform in init and update, a chain of two messages"),
    "E2Order": ({}, None, None, "step 4: order of synchronous commands, batches reversed, nested batch and Cmd.map"),
    "E2Tasks": ({}, None, None, "step 4: andThen, onError, fail, attempt, map2, sequence, mapError, silent failure, spawn and kill"),
    "G17": ({}, 0, None, "G17: 100000 Task.perform steps over a Dict and Array model, 0 model copies"),
    "G17c": ({}, 1, None, "G17 (c): a closed literal init model, exactly 1 model copy"),
    "E2Sleep": (T, None, None, "step 5: Process.sleep order, sleep 0 yields, a killed sleeper never wakes, the loop ends"),
    "E2Time": (T, None, None, "step 5: Time.every until unsubscribed, Time.now, here and getZoneName (TZ=UTC)"),
    "G17a": (T, ">0", None, "G17 (a): a Time.every tagger captures the model: copies, the old model keeps its values"),
    "G17s": (T, ">0", None, "G17 (b): Task.perform (Done m) (Process.sleep 0) captures the model: copies"),
}


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, **kw)


def goldens(a, names):
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    proj = os.path.join(tmp, "ref"); os.makedirs(os.path.join(proj, "src"))
    shutil.copy(os.path.join(HERE, "effects2", "elm.json"), proj)
    bad = 0
    for n in names:
        env, _, _, _ = TESTS[n]
        shutil.copy(os.path.join(HERE, "effects2", "src", n + ".fic"), os.path.join(proj, "src", n + ".elm"))
        js = os.path.join(tmp, n + ".js")
        p = run([os.path.abspath(a.ref), "make", "src/%s.elm" % n, "--output=" + js], cwd=proj, env=dict(os.environ, ELM_HOME=a.elm_home))
        if p.returncode != 0:
            print("FAIL %s: the reference compiler: %s" % (n, (p.stdout + p.stderr).decode()[-400:])); bad += 1; continue
        r = run(["node", os.path.join(HERE, "effects2", "ref", "run.js"), js, n], env=dict(os.environ, **env), timeout=600)
        out = r.stdout.decode()
        open(os.path.join(HERE, "expected", "e2_%s.out" % n.lower()), "w").write(out)
        # E1 open point (b): the order in which Elm registers the managers and ports (_Platform_effectManagers)
        order = re.findall(r"_Platform_effectManagers\['(\w+)'\] = |_Platform_(?:outgoing|incoming)Port\('(\w+)'", open(js).read())
        names = [a or b for a, b in order]
        of = os.path.join(HERE, "expected", "e2_%s.order" % n.lower())
        if names: open(of, "w").write(" ".join(names) + "\n")
        elif os.path.exists(of): os.remove(of)
        print("golden %s: %d lines%s" % (n, out.count("\n"), "" if r.returncode == 0 else " (node exit %d)" % r.returncode))
    shutil.rmtree(tmp, ignore_errors=True)
    return bad


def check(a, names):
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    d = os.path.join(tmp, "effects2"); shutil.copytree(os.path.join(HERE, "effects2"), d, ignore=shutil.ignore_patterns("elm-stuff", "ref"))
    bad = 0

    def report(ok, what, detail=""):
        nonlocal bad
        print(("ok   " if ok else "FAIL ") + what + ("" if ok else "  " + detail)); bad += 0 if ok else 1

    for n in names:
        env, copies, filt, _ = TESTS[n]
        want = open(os.path.join(HERE, "expected", "e2_%s.out" % n.lower())).read()
        if filt: want = filt(want)
        for flag in ("--rc", "--no-rc"):
            c = os.path.join(tmp, n + flag + ".c")
            p = run([os.path.abspath(a.elm), "make", "src/%s.fic" % n, "--output=" + c, flag], cwd=d,
                    env=dict(os.environ, ELM_HOME=a.elm_home, FICCUS_MANAGER_ORDER="1"))
            if p.returncode != 0:
                report(False, "%s %s compiles" % (n, flag), (p.stdout + p.stderr).decode()[-400:]); continue
            of = os.path.join(HERE, "expected", "e2_%s.order" % n.lower())
            if flag == "--rc" and os.path.exists(of):
                m = re.search(r"FICCUS_MANAGER_ORDER: \[(.*)\]", (p.stdout + p.stderr).decode())
                got = [x.split(":")[-1].split(".")[-1] if k == "EManager" else x for k, x in re.findall(r'(EManager|EPortOut|EPortIn) "([^"]*)"', m.group(1))] if m else []
                want_o = open(of).read().split()
                report(got == want_o, "%s: managers and ports in Elm's order (%s)" % (n, " ".join(want_o)), "got " + " ".join(got))
            for tag, cf in ((("O2", ["-O2"]), ("san", SAN)) if flag == "--rc" else (("O2", ["-O2"]),)):
                exe = os.path.join(tmp, n + flag + tag)
                b = run(["gcc", "-std=c99", "-ffp-contract=off", "-w", *cf, "-DFIC_STATS", "-I", RT, c, "-o", exe, "-lm"])
                if b.returncode != 0:
                    report(False, "%s %s %s builds" % (n, flag, tag), b.stderr.decode()[-300:]); continue
                r = run([exe], env=dict(os.environ, **env), timeout=600)
                out, err = r.stdout.decode(), r.stderr.decode()
                got = filt(out) if filt else out
                m = re.search(r"FIC_STATS model: steps (\d+) inplace (\d+) copied (\d+) vec_copy (\d+) reuse_miss (\d+) model_copies (\d+)", err)
                mc = int(m.group(6)) if m else -1
                live = re.search(r"FIC_STATS: allocs \d+ live (\d+)", err)
                ok = r.returncode == 0 and got == want
                if flag == "--rc": ok = ok and live is not None and live.group(1) == "0"
                if copies is not None and flag == "--rc": ok = ok and (mc > 0 if copies == ">0" else mc == copies)
                report(ok, "%s %s %s: output = Elm%s%s" % (n, flag, tag, ", live 0" if flag == "--rc" else "",
                                                           (", model copies %d (want %s)" % (mc, copies)) if copies is not None and flag == "--rc" else ""),
                       "exit %d\n--- got\n%s\n--- stderr\n%s" % (r.returncode, got[-600:], err[-600:]))
    shutil.rmtree(tmp, ignore_errors=True)
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm"); ap.add_argument("--elm-home", required=True)
    ap.add_argument("--goldens", action="store_true"); ap.add_argument("--ref")
    ap.add_argument("--only")
    a = ap.parse_args()
    names = [n for n in TESTS if not a.only or any(o == n for o in a.only.split(","))]
    bad = goldens(a, names) if a.goldens else check(a, names)
    print("effects_e2: %s" % ("%d failures" % bad if bad else "all ok"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
