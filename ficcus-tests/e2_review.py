#!/usr/bin/env python3
"""E2 review (docs/E2-REVIEW.md): programs in ficcus-tests/e2review/src/*.fic, compared with Elm 0.19.3 under node.

Each program is its own Elm reference (as in effects_e2.py): --goldens copies the source tree to a scratch Elm project as .elm files,
compiles with the reference compiler, runs under node with effects2/ref/run.js and writes e2review/expected/<name>.out (and .order,
the order of _Platform_effectManagers). A check compiles the program --rc (gcc -O2, ASan + UBSan without the pool, -DFIC_DROP_ALL)
and --no-rc (-O2), runs it and compares stdout and the exit status; under --rc a program that ends normally must say live 0.

Kinds: gate (must pass: the gate list), target (fails today; a required fix makes it pass: run with --targets), reject (Ficcus must
stop with a compile error matching a pattern; programs in e2review/rejects, an Elm project with elm/browser and elm/http), info
(a divergence to decide, printed, never counted).

  python3 ficcus-tests/e2_review.py --elm bin/elmficNN --elm-home H [--targets] [--only a,b]     exit 1 on a failing gate (or target)
  python3 ficcus-tests/e2_review.py --goldens --ref bin/elm0193 --elm-home H [--only a,b]"""
import argparse, os, re, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
D = os.path.join(HERE, "e2review")
RT = os.path.join(HERE, "..", "..", "targets", "c")
RUNJS = os.path.join(HERE, "effects2", "ref", "run.js")
SAN = ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-g", "-DFIC_NO_POOL", "-Wno-maybe-uninitialized"]
T = {"FIC_TIME": "1700000000000", "TZ": "UTC"}

# name: (kind, environment, expected exit status, question and what it tests). "__src" names the program when several entries
# run one program in different environments.
TESTS = {
    "R1Kill": ("gate", T, 0, "Q1: kill while queued after Time.now, while sleeping, after it finished; kill from a later update"),
    "R2Spawn": ("gate", T, 0, "Q1: spawn during the own step, three deep, with Time.now and sleep 0; in sequence and map2"),
    "R3Yield": ("gate", T, 0, "Q1/Q5: sleep 0 yields to the host, Time.now/here/getZoneName only to the queue; delays 0, 0.5, -3, NaN, 1"),
    "R5PortBacklog": ("gate", T, 0, "Q1/Q6: fx messages reach the outgoing port's manager while it sleeps 0 (Elm re-runs the binding)"),
    "R6Maps": ("gate", dict(T, FIC_PORTS_IN="{D}/ports/R6Maps.in"), 0,
               "Q2/Q3: nested Cmd.map/Sub.map over Task, Random, Time and ports at many class pairs; tagger calls logged"),
    "R7OrderA": ("gate", T, 0, "Q4: manager and port order with permuted helper modules (variant A)"),
    "R7OrderB": ("gate", T, 0, "Q4: variant B"),
    "R7OrderC": ("gate", T, 0, "Q4: variant C (Random registered before Task: observable)"),
    "R8Every": ("gate", T, 0, "Q5: two intervals, unsubscribed, kept, subscribed again"),
    "R10Zone": ("gate", T, 0, "Q9: Time.here and getZoneName, TZ=UTC"),
    "R10ZoneTokyo": ("gate", dict(T, TZ="Asia/Tokyo", __src="R10Zone"), 0, "Q9: TZ=Asia/Tokyo (no daylight time, same name in ICU)"),
    "R11Ports": ("gate", dict(T, FIC_PORTS_IN="{D}/ports/R11Ports.in"), 0,
                 "Q6: port order, record field order, output, Json.Value both ways, Int 1.0/1e3/-0/3e9"),
    "R11PortsBad": ("gate", dict(T, FIC_PORTS_IN="{D}/ports/R11PortsBad.in"), 1, "Q6: an incoming value that does not decode: crash 4, exit 1"),
    "R12Crash": ("gate", T, 1, "Q7: Debug.todo with a timer pending and a port message queued"),
    # targets of the review, gates since fixes 2 and 3
    "R4Delay": ("gate", T, 0, "Q5 (fix 2): node truncates a fractional delay and makes a delay above 2^31-1 ms (or Infinity) 1 ms"),
    "R9Slow": ("gate", {"TZ": "UTC"}, 0, "Q5 (fix 3, real time): after a slow update an interval does not fire its missed ticks back to back"),
    # divergences to decide (not counted)
    "R1KillTwice": ("info", T, 0, "Q1: Elm crashes on a second kill of a killed process (TypeError); Ficcus continues"),
    "R10ZoneKolkata": ("info", dict(T, TZ="Asia/Kolkata", __src="R10Zone"), 0, "Q9: ICU names the zone Asia/Calcutta, Ficcus gives TZ as set"),
    "R11PortsBig": ("info", dict(T, FIC_PORTS_IN="{D}/ports/R11PortsBig.in", __src="R11Ports"), 0,
                    "Q6: an integer beyond 2^53 through Json.Value keeps its digits (decision L21), JavaScript rounds it"),
}
# rejects: (program, pattern the compile error must match, what it tests); "target" when Ficcus does not reject it today
# E3a/E3b: X1Flags, X1FlagsString, X2ArrayPortOut and X3ArrayPortIn (flags and Array payloads, compile errors until E3) run since E3 and
# are compared with Elm by ficcus-tests/effects_e3.py (their sources moved to effects3/src)
REJECTS = {
    "X4BrowserEvents": ("gate", r"FICCUS: the program cannot be compiled", "Q4: Browser.Events in a worker (message names kernels)"),
    "X5Http": ("gate", r"FICCUS: the program cannot be compiled", "Q4: Http in a worker (message names kernels)"),
    "X6Element": ("gate", r"FICCUS: the program cannot be compiled", "Q4: Browser.element"),
}


def envOf(env):
    return {k: v.replace("{D}", D) for k, v in env.items() if not k.startswith("__")}


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, **kw)


def project(tmp, src, ext):
    """a copy of e2review (or e2review/rejects) with the sources renamed to .elm for the reference compiler"""
    proj = os.path.join(tmp, "proj")
    shutil.rmtree(proj, ignore_errors=True)
    shutil.copytree(src, proj, ignore=shutil.ignore_patterns("elm-stuff", "expected", "ports", "rejects"))
    if ext == ".elm":
        for root, _, files in os.walk(os.path.join(proj, "src")):
            for f in files:
                if f.endswith(".fic"):
                    os.rename(os.path.join(root, f), os.path.join(root, f[:-4] + ".elm"))
    return proj


def goldens(a, names):
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    proj = project(tmp, D, ".elm")
    built, bad = {}, 0
    for n in names:
        kind, env, _, _ = TESTS[n]
        src = env.get("__src", n)
        js = os.path.join(tmp, src + ".js")
        if src not in built:
            p = run([os.path.abspath(a.ref), "make", "src/%s.elm" % src, "--output=" + js], cwd=proj, env=dict(os.environ, ELM_HOME=a.elm_home))
            built[src] = p.returncode == 0
            if p.returncode != 0:
                print("FAIL %s: the reference compiler: %s" % (n, (p.stdout + p.stderr).decode()[-400:])); bad += 1; continue
        r = run(["node", RUNJS, js, src], env=dict(os.environ, **envOf(env)), timeout=600)
        open(os.path.join(D, "expected", "%s.out" % n), "w").write(r.stdout.decode())
        order = re.findall(r"_Platform_effectManagers\['(\w+)'\] = |_Platform_(?:outgoing|incoming)Port\(\s*'(\w+)'", open(js).read())
        of = os.path.join(D, "expected", "%s.order" % n)
        if order: open(of, "w").write(" ".join(x or y for x, y in order) + "\n")
        elif os.path.exists(of): os.remove(of)
        print("golden %s: %d lines, node exit %d" % (n, r.stdout.decode().count("\n"), r.returncode))
    shutil.rmtree(tmp, ignore_errors=True)
    return bad


def check(a, names, targets):
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    proj = project(tmp, D, ".fic")
    counts = {"gate": [0, 0], "target": [0, 0], "info": [0, 0]}

    def report(kind, ok, what, detail=""):
        counts[kind][0 if ok else 1] += 1
        label = ("ok   " if ok else "FAIL ") if kind == "gate" else ("%-5s" % ("ok" if ok else kind.upper()) + "[%s] " % kind)
        print(label + what + ("" if ok or kind == "info" else "  " + detail) + (("  (differs: " + detail.split("\n")[0] + ")") if kind == "info" and not ok else ""))

    compiled = {}
    for n in names:
        kind, env, want_exit, _ = TESTS[n]
        if kind == "target" and not targets: continue
        src = env.get("__src", n)
        want = open(os.path.join(D, "expected", "%s.out" % n)).read()
        for flag in ("--rc", "--no-rc") if kind != "info" else ("--rc",):
            c = os.path.join(tmp, src + flag + ".c")
            if (src, flag) not in compiled:
                p = run([os.path.abspath(a.elm), "make", "src/%s.fic" % src, "--output=" + c, flag], cwd=proj,
                        env=dict(os.environ, ELM_HOME=a.elm_home, FICCUS_MANAGER_ORDER="1"))
                compiled[(src, flag)] = (p.returncode, (p.stdout + p.stderr).decode())
                of = os.path.join(D, "expected", "%s.order" % src)
                if p.returncode == 0 and flag == "--rc" and os.path.exists(of) and kind != "info":
                    m = re.search(r"FICCUS_MANAGER_ORDER: \[(.*)\]", compiled[(src, flag)][1])
                    got = [x.split(":")[-1].split(".")[-1] if k == "EManager" else x for k, x in re.findall(r'(EManager|EPortOut|EPortIn) "([^"]*)"', m.group(1))] if m else []
                    wo = open(of).read().split()
                    report(kind, got == wo, "%s: managers and ports in Elm's order (%s)" % (src, " ".join(wo)), "got " + " ".join(got))
            rc, log = compiled[(src, flag)]
            if rc != 0:
                report(kind, False, "%s %s compiles" % (n, flag), log[-400:]); continue
            builds = (("O2", ["-O2"]), ("san", SAN), ("dropall", ["-O1", "-DFIC_DROP_ALL"])) if flag == "--rc" and kind != "info" else (("O2", ["-O2"]),)
            for tag, cf in builds:
                exe = os.path.join(tmp, "%s%s%s" % (n, flag, tag))
                b = run(["gcc", "-std=c99", "-ffp-contract=off", "-w", *cf, "-DFIC_STATS", "-I", RT, c, "-o", exe, "-lm"])
                if b.returncode != 0:
                    report(kind, False, "%s %s %s builds" % (n, flag, tag), b.stderr.decode()[-300:]); continue
                r = run([exe], env=dict(os.environ, **envOf(env)), timeout=600)
                out, err = r.stdout.decode(), r.stderr.decode()
                ok = r.returncode == want_exit and out == want
                live = re.search(r"FIC_STATS: allocs \d+ live (\d+)", err)
                if flag == "--rc" and want_exit == 0: ok = ok and live is not None and live.group(1) == "0"
                if tag == "dropall" and want_exit == 0: ok = ok and re.search(r"FIC_DROP_ALL: \d+ objects checked, 0 bad, 0 live after the free", err) is not None
                if tag == "san": ok = ok and "ERROR: AddressSanitizer" not in err and "runtime error:" not in err
                diff = [(i, x, y) for i, (x, y) in enumerate(zip(want.split("\n"), out.split("\n"))) if x != y]
                first = ("line %d: want %r got %r" % diff[0]) if diff else ("%d lines wanted, %d got" % (want.count("\n"), out.count("\n")))
                report(kind, ok, "%s %s %s: output = Elm, exit %d%s" % (n, flag, tag, want_exit, ", live 0" if flag == "--rc" and want_exit == 0 else ""),
                       "exit %d; %s\n--- stderr\n%s" % (r.returncode, first, err[-400:]))
    shutil.rmtree(tmp, ignore_errors=True)
    return counts


def rejects(a, names, targets):
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    proj = project(tmp, os.path.join(D, "rejects"), ".fic")
    counts = {"gate": [0, 0], "target": [0, 0]}
    for n in names:
        kind, pat, what = REJECTS[n]
        if kind == "target" and not targets: continue
        p = run([os.path.abspath(a.elm), "make", "src/%s.fic" % n, "--output=" + os.path.join(tmp, n + ".c"), "--rc"], cwd=proj,
                env=dict(os.environ, ELM_HOME=a.elm_home))
        log = (p.stdout + p.stderr).decode()
        ok = p.returncode != 0 and re.search(pat, log) is not None
        counts[kind][0 if ok else 1] += 1
        print(("ok   " if ok else "FAIL ") + ("" if kind == "gate" else "[target] ") + "%s: a compile error (%s)" % (n, what)
              + ("" if ok else "  exit %d: %s" % (p.returncode, log.strip()[-200:])))
    shutil.rmtree(tmp, ignore_errors=True)
    return counts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm"); ap.add_argument("--elm-home", required=True)
    ap.add_argument("--goldens", action="store_true"); ap.add_argument("--ref")
    ap.add_argument("--targets", action="store_true", help="also run the targets (fail until the required fixes)")
    ap.add_argument("--only")
    a = ap.parse_args()
    pick = lambda xs: [n for n in xs if not a.only or n in a.only.split(",")]
    if a.goldens:
        bad = goldens(a, pick(TESTS))
        print("e2_review goldens: %s" % ("%d failures" % bad if bad else "all ok"))
        return 1 if bad else 0
    c = check(a, pick(TESTS), a.targets)
    r = rejects(a, pick(REJECTS), a.targets)
    gate_bad = c["gate"][1] + r["gate"][1]
    tgt_bad = c["target"][1] + r["target"][1]
    print("e2_review: gates %s; targets %s; info: %d differ"
          % ("all ok" if gate_bad == 0 else "%d failures" % gate_bad,
             ("%d ok, %d fail" % (c["target"][0] + r["target"][0], tgt_bad)) if a.targets else "not run", c["info"][1]))
    return 1 if gate_bad or (a.targets and tgt_bad) else 0


if __name__ == "__main__":
    sys.exit(main())
