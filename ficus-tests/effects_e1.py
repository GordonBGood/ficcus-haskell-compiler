#!/usr/bin/env python3
"""Effects slice E1 (docs/EFFECTS-CHECK.md steps 1 to 3; programs in ficus-tests/effects/, Elm 0.19.3 goldens in expected/):

  FxManagers  step 2: the .mono listing has the Task manager cloned from Elm (init, onEffects, onSelfMsg at Msg, cmdMap at the
              Cmd.map pair) and the manager table in main; since E2 (the scheduler) the C program runs and ends with nothing live.
  S2Perform   review fix 3: Task.perform in update stopped with the E2 message in E1; since E2 it compiles in both modes and its
              output equals Elm's (also a test of ficus-tests/effects_e2.py).
  SubsOrder   step 3: subscriptions runs after init, as in Elm (golden), --rc and --no-rc.
  G17b        step 3: N = 100000 steps of the typed stepper (-DFIC_STEP_TEST=100000) over a record model with a Dict and an Array;
  G17bFields  output = golden, live 0, and the FIC_STATS model line: 0 model copies, 199200 updates in place, 0 reuse misses.
              The switches show what each part is for: FICUS_NO_MODEL_SEED=1 copies in G17bFields (ModelUnpack's `let _mf = m.f`
              bindings are field reads, so the ordinary rules borrow the model), as on elmficG70a. ModelUnpack is on by default (E1p
              review fix 2); with FICUS_NO_MODEL_UNPACK=1 the leaf split in Rc alone gives 0 copies, also without the seed (the
              inference then sees `Array.set .. m.a`); without both (FICUS_NO_LEAFSPLIT=1 FICUS_NO_MODEL_UNPACK=1) both programs copy.
Each counted program is built with gcc -O2 and under ASan + UBSan (no pool).
  python3 ficus-tests/effects_e1.py --elm bin/elmficNN --elm-home H        exit 1 on any failure"""
import argparse, os, re, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
RT = os.path.join(HERE, "..", "..", "targets", "c")
SAN = ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-g", "-DFIC_NO_POOL", "-Wno-maybe-uninitialized"]
N = 100000
# (program, golden, switches, expected model copies: 0 or ">0")
NOSPLIT = {"FICUS_NO_LEAFSPLIT": "1"}
NEITHER = {"FICUS_NO_LEAFSPLIT": "1", "FICUS_NO_MODEL_UNPACK": "1"}
NOUNPACK = {"FICUS_NO_MODEL_UNPACK": "1"}
G17 = [("G17b", "g17b", {}, "0"), ("G17b", "g17b", NOUNPACK, "0"), ("G17b", "g17b", NOSPLIT, "0"), ("G17b", "g17b", NEITHER, ">0"),
       ("G17b", "g17b", {"FICUS_NO_MODEL_SEED": "1"}, "0"),
       ("G17bFields", "g17b", {}, "0"), ("G17bFields", "g17b", {"FICUS_NO_MODEL_SEED": "1"}, ">0"),
       ("G17bFields", "g17b", dict(NOSPLIT, FICUS_NO_MODEL_SEED="1"), ">0"), ("G17bFields", "g17b", dict(NOUNPACK, FICUS_NO_MODEL_SEED="1"), "0"),
       ("G17bFields", "g17b", NOUNPACK, "0"), ("G17bFields", "g17b", NOSPLIT, "0"), ("G17bFields", "g17b", NEITHER, ">0")]


def make(a, d, mod, out, flags, env=None):
    return subprocess.run([os.path.abspath(a.elm), "make", "src/%s.fic" % mod, "--output=" + out] + flags, cwd=d, capture_output=True,
                          env=dict(os.environ, ELM_HOME=a.elm_home, **(env or {})))


def build_run(c, exe, flags):
    b = subprocess.run(["gcc", "-std=c99", "-ffp-contract=off", "-w", *flags, "-I", RT, c, "-o", exe, "-lm"], capture_output=True)
    if b.returncode != 0: return None, "gcc: " + b.stderr.decode()[-300:]
    r = subprocess.run([exe], capture_output=True)
    return r, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--elm-home", required=True)
    a = ap.parse_args()
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    d = os.path.join(tmp, "effects"); shutil.copytree(os.path.join(HERE, "effects"), d, ignore=shutil.ignore_patterns("elm-stuff", "ref"))
    bad = 0

    def report(ok, what, detail=""):
        nonlocal bad
        print(("ok   " if ok else "FAIL ") + what + ("" if ok else "  " + detail)); bad += 0 if ok else 1

    # step 2
    p = make(a, d, "FxManagers", os.path.join(tmp, "fx.mono"), [])
    mono = open(os.path.join(tmp, "fx.mono")).read() if p.returncode == 0 else ""
    want = ["def: elm/core:Task.init ", "def: elm/core:Task.onEffects ", "def: elm/core:Task.onSelfMsg ", "def: elm/core:Task.cmdMap ",
            "Kernel ficus:manager@elm/core:Task", "Kernel elm/core:Platform.leaf@elm/core:Task"]
    missing = [w for w in want if w not in mono]
    report(p.returncode == 0 and not missing, "FxManagers .mono: Task manager clones and table", "missing " + ", ".join(missing))
    # E2: the scheduler exists, the program runs (it prints nothing) and ends with nothing live
    c = os.path.join(tmp, "fx.c"); p = make(a, d, "FxManagers", c, ["--rc"])
    r, err = build_run(c, os.path.join(tmp, "fx"), SAN + ["-DFIC_STATS"]) if p.returncode == 0 else (None, (p.stdout + p.stderr).decode()[-300:])
    report(r is not None and r.returncode == 0 and " live 0 " in r.stderr.decode(), "FxManagers C: runs on the scheduler (E2), live 0",
           err or (r.stdout + r.stderr).decode()[-300:])

    # E1 review fix 3, then E2: a worker whose update mentions Task.perform compiles in both modes and prints what Elm prints
    for flags in (["--rc"], ["--no-rc"]):
        c = os.path.join(tmp, "s2.c"); p = make(a, d, "S2Perform", c, flags)
        r, err = build_run(c, os.path.join(tmp, "s2"), ["-O2"]) if p.returncode == 0 else (None, (p.stdout + p.stderr).decode()[-400:])
        report(r is not None and r.returncode == 0 and r.stdout.decode() == "init: 1\n", "S2Perform %s: Task.perform in update compiles and runs (E2)" % flags[0],
               err or (r.stdout + r.stderr).decode()[-300:])

    # step 3: order of init and subscriptions
    want = open(os.path.join(HERE, "expected", "subsorder.out")).read()
    for flags in (["--rc"], ["--no-rc"]):
        c = os.path.join(tmp, "so.c"); p = make(a, d, "SubsOrder", c, flags)
        if p.returncode != 0: report(False, "SubsOrder %s compiles" % flags[0], (p.stdout + p.stderr).decode()[-300:]); continue
        for tag, cf in (("O2", ["-O2", "-DFIC_STATS"]), ("san", SAN + ["-DFIC_STATS"])):
            if flags == ["--no-rc"] and tag == "san": continue          # the no-RC build never frees: ASan's leak check does not apply
            r, err = build_run(c, os.path.join(tmp, "so_" + tag), cf)
            ok = r is not None and r.returncode == 0 and r.stdout.decode() == want and (flags == ["--no-rc"] or " live 0 " in r.stderr.decode())
            report(ok, "SubsOrder %s %s: output = Elm, live 0" % (flags[0], tag), err or (r.stdout.decode() + r.stderr.decode())[-300:])

    # step 3: G17b
    for mod, gold, env, expect in G17:
        want = open(os.path.join(HERE, "expected", gold + ".out")).read()
        label = mod + (" [" + ",".join("%s=%s" % kv for kv in env.items()) + "]" if env else "")
        c = os.path.join(tmp, "g.c"); p = make(a, d, mod, c, ["--rc"], env)
        if p.returncode != 0: report(False, label + " compiles", (p.stdout + p.stderr).decode()[-300:]); continue
        for tag, cf in (("O2", ["-O2"]), ("san", SAN)):
            r, err = build_run(c, os.path.join(tmp, "g_" + tag), cf + ["-DFIC_STATS", "-DFIC_STEP_TEST=%d" % N])
            if r is None: report(False, label + " " + tag, err); continue
            e = r.stderr.decode()
            m = re.search(r"FIC_STATS model: steps (\d+) inplace (\d+) copied (\d+) vec_copy (\d+) reuse_miss (\d+) model_copies (\d+)", e)
            copies = int(m.group(6)) if m else -1
            ok = (r.returncode == 0 and r.stdout.decode() == want and " live 0 " in e and m is not None and int(m.group(1)) == N
                  and (copies == 0 and int(m.group(5)) == 0 if expect == "0" else copies > 0))
            report(ok, "%s %s: output = Elm, live 0, model copies %s (want %s)%s" % (label, tag, copies, expect, (": " + m.group(0)[17:]) if m else ""),
                   (r.stdout.decode() + e)[-400:])
    # the no-RC oracle of G17b
    c = os.path.join(tmp, "gn.c"); p = make(a, d, "G17b", c, ["--no-rc"])
    r, err = build_run(c, os.path.join(tmp, "gn"), ["-O2", "-DFIC_STEP_TEST=%d" % N]) if p.returncode == 0 else (None, (p.stdout + p.stderr).decode()[-300:])
    report(r is not None and r.returncode == 0 and r.stdout.decode() == open(os.path.join(HERE, "expected", "g17b.out")).read(), "G17b --no-rc: output = Elm", err or "")
    shutil.rmtree(tmp, ignore_errors=True)
    print("effects_e1: %s" % ("%d failures" % bad if bad else "all ok"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
