#!/usr/bin/env python3
"""Run the realistic programs of ficus-tests/programs/NN-name/ (src/Main.fic, elm.json).

Elm compatible programs (no file `expected.out`): oracle = Elm 0.19.3 (bin/elm0193) compiled to JS and run under node (src copied to .elm).
Ficus only programs (`expected.out` present, computed independently by `expected.py`): oracle = that file.
Modes (all serial, compiler and run capped by tools/safe): plain (--no-rc), dropall (--no-rc -DFIC_DROP_ALL), rc (--rc, counted + ASan/UBSan,
FIC_STATS live 0). Elm compatible programs also JS identity: NEW make X.elm vs elm0193 (byte equal).

  python3 ficus-tests/programs/run.py --elm bin/elmficA14 --elm-home H --work W [--only 01,02] [--modes plain,dropall,rc,js]
"""
import argparse, os, shutil, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
WS = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
SAFE = os.path.join(WS, "tools", "safe")
RT = os.path.join(WS, "targets", "c")
SAN = ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-g", "-DFIC_NO_POOL"]

def sh(cmd, cwd, env, timeout="60", mem="3G"):
    t = time.time()
    p = subprocess.run([SAFE] + cmd, cwd=cwd, env=dict(env, SAFE_TIMEOUT=timeout, SAFE_MEM=mem), capture_output=True)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace"), time.time() - t

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--ref", default=os.path.join(WS, "bin", "elm0193"))
    ap.add_argument("--elm-home", required=True); ap.add_argument("--work", required=True)
    ap.add_argument("--only"); ap.add_argument("--modes", default="plain,dropall,rc,js"); ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    a.elm, a.ref, a.elm_home, a.work = [os.path.abspath(x) for x in (a.elm, a.ref, a.elm_home, a.work)]
    allmodes = a.modes.split(",")
    env = dict(os.environ, ELM_HOME=a.elm_home)
    names = sorted(d for d in os.listdir(HERE) if os.path.isdir(os.path.join(HERE, d)) and d[:2].isdigit())
    if a.only: names = [n for n in names if n[:2] in a.only.split(",")]
    passed = failed = 0
    for n in names:
        w = os.path.join(a.work, n); shutil.rmtree(w, ignore_errors=True); shutil.copytree(os.path.join(HERE, n), w)
        mod = "Main"
        ficonly = os.path.exists(os.path.join(w, "expected.out"))
        bad = []
        mf = os.path.join(w, "modes")     # optional file: the modes this program is run in (large no-RC allocation is not possible)
        modes = [m for m in allmodes if m in open(mf).read().split()] if os.path.exists(mf) else allmodes
        if ficonly: want = open(os.path.join(w, "expected.out"), encoding="utf-8").read()
        else:
            for sub in ("ref", "js"):       # Elm sources in their own copies (Main.fic and Main.elm must not meet in one project)
                os.makedirs(os.path.join(w, sub, "src")); shutil.copy(os.path.join(w, "elm.json"), os.path.join(w, sub))
                shutil.copy(os.path.join(w, "src", mod + ".fic"), os.path.join(w, sub, "src", mod + ".elm"))
            rc, o, e, t = sh([a.ref, "make", "src/" + mod + ".elm", "--output=../ref.js"], os.path.join(w, "ref"), env)
            if rc: print("%s: ORACLE COMPILE FAIL %s" % (n, (o + e)[-300:])); failed += 1; continue
            open(os.path.join(w, "run.js"), "w").write("require('./ref.js').Elm.%s.init();\n" % mod)
            rc, want, e, t = sh(["node", "run.js"], w, env)
            if rc: print("%s: ORACLE RUN FAIL rc=%d %s" % (n, rc, e[-300:])); failed += 1; continue
            open(os.path.join(w, "oracle.out"), "w").write(want)
        res = []
        for mode in modes:
            if mode == "js":
                if ficonly: continue
                rc, o, e, t = sh([a.elm, "make", "src/" + mod + ".elm", "--output=../new.js"], os.path.join(w, "js"), env)
                if rc: bad.append("js compile: " + (o + e)[-200:]); continue
                if open(os.path.join(w, "ref.js"), "rb").read() != open(os.path.join(w, "new.js"), "rb").read(): bad.append("js identity differs")
                else: res.append("js ok")
                continue
            rcflag = "--rc" if mode == "rc" else "--no-rc"
            c = os.path.join(w, "x_%s.c" % mode)
            rc, o, e, ct = sh([a.elm, "make", "src/" + mod + ".fic", "--output=" + c, rcflag], w, env, timeout="120")
            if rc: bad.append("%s: compiler exit %d %s" % (mode, rc, (o + e)[-300:])); continue
            flags = ["-std=c99", "-O2", "-ffp-contract=off", "-w", "-I", RT]
            if mode == "dropall": flags += ["-DFIC_DROP_ALL"]
            if mode == "rc": flags += ["-DFIC_STATS"] + SAN
            exe = os.path.join(w, "x_" + mode)
            rc, o, e, bt = sh(["gcc"] + flags + [c, "-o", exe, "-lm"], w, env, timeout="180")
            if rc: bad.append("%s: gcc failed %s" % (mode, e[-300:])); continue
            rc, o, e, rt = sh([exe], w, env, timeout="30")
            tag = "%s(cc %.1fs run %.2fs)" % (mode, ct, rt)
            if ct > 60: bad.append("%s: compile time %.0fs" % (mode, ct))
            if rc != 0: bad.append("%s: exit %d stderr %s" % (mode, rc, e[-300:]))
            elif o != want:
                open(os.path.join(w, "got_%s.out" % mode), "w").write(o)
                bad.append("%s: output differs (see %s/got_%s.out)" % (mode, w, mode))
            elif mode == "rc" and not any(" live 0 " in l and l.startswith("FIC_STATS") for l in e.splitlines()): bad.append("rc: not live 0: " + e[-200:])
            elif mode == "dropall" and " 0 bad, 0 live" not in e: bad.append("dropall check: " + e[-200:])
            else: res.append(tag)
        if bad: failed += 1; print("FAIL %s\n   %s" % (n, "\n   ".join(bad)))
        else: passed += 1; print("ok   %s  %s" % (n, " ".join(res)))
    print("passed %d failed %d" % (passed, failed))
    return 1 if failed else 0

if __name__ == "__main__": sys.exit(main())
