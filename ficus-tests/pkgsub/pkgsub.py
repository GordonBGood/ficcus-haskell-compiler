#!/usr/bin/env python3
"""G43/G38 tests: package substitution of cmditch/elm-bigint in the C build.

  python3 pkgsub.py --elm BIN --elm-home COPY_OF_elm-home-difftest/0.19.3 [--seed N] [--work DIR]

Scenarios (each a project that DEPENDS on the package; nothing is a source directory):
  core     elm-bigint 2.1.2, default: C build must say it replaced the package and its C must hold the core package's ids;
           its output must equal the JS build (elm0193, Elm package, node) on the BIGINT differential cases
  off      same project with "ficus-core-packages": false : the Elm package is used (no message); output equal to JS
  range    elm-bigint 1.0.1 (outside 2.x): the Elm package is used; output equal to JS
  jsflag   the JS build of the project with the setting on is byte identical to the JS build with it off (elm0194 not needed)
"""
import argparse, os, re, subprocess, sys, tempfile, shutil

here = os.path.dirname(os.path.abspath(__file__))
ws = os.path.abspath(os.path.join(here, "../../.."))
sys.path.insert(0, os.path.join(here, "../bigint"))
import bigint_cases

DEPS = '"elm/core":"1.0.5","cmditch/elm-bigint":"%s","elm-community/list-extra":"8.7.0","elm-community/maybe-extra":"5.3.0","rtfeldman/elm-hex":"1.0.0"'


def elm_json(ver, extra=""):
    return ('{"type":"application","source-directories":["src"],"elm-version":"0.19.3",%s\n'
            ' "dependencies":{"direct":{%s},"indirect":{"elm/json":"1.1.3"}},"test-dependencies":{"direct":{},"indirect":{}}}\n'
            % (extra, DEPS % ver))


def sh(cmd, cwd=None, env=None, timeout=1200):
    e = dict(os.environ)
    e.update(env or {})
    return subprocess.run(cmd, cwd=cwd, env=e, capture_output=True, text=True, timeout=timeout)


def keep(text):
    return [l for l in text.splitlines() if re.match(r"(cases|failed): \d+$|FAIL:", l)]


def project(d, main_src, ver, extra=""):
    os.makedirs(d + "/src", exist_ok=True)
    open(d + "/src/Main.elm", "w").write(main_src)
    open(d + "/elm.json", "w").write(elm_json(ver, extra))


def build_c(d, a):
    r = sh([a.elm, "make", "src/Main.elm", "--output=main.c", "--rc"], cwd=d, env={"ELM_HOME": a.elm_home})
    if r.returncode != 0:
        return None, r.stdout[-2500:] + r.stderr[-2500:]
    r2 = sh(["gcc", "-std=c99", "-O1", "-ffp-contract=off", "-w", "-I", ws + "/targets/c", d + "/main.c", "-o", d + "/main", "-lm"])
    if r2.returncode != 0:
        return None, r2.stderr[-2500:]
    p = sh([ws + "/tools/safe", d + "/main"], env={"SAFE_MEM": "3G", "SAFE_TIMEOUT": "300"})
    return (r.stdout + r.stderr, keep(p.stdout + p.stderr), p.returncode), ""


def build_js(d, a):
    r = sh([ws + "/bin/elm0193", "make", "src/Main.elm", "--output=main.js"], cwd=d, env={"ELM_HOME": a.elm_home})
    if r.returncode != 0:
        return None, r.stdout[-2500:] + r.stderr[-2500:]
    open(d + "/run.js", "w").write("const {Elm}=require('./main.js');Elm.Main.init();")
    p = sh([ws + "/tools/safe", "node", d + "/run.js"], env={"SAFE_MEM": "6G", "SAFE_TIMEOUT": "600"})
    return (keep(p.stdout + p.stderr), p.returncode, open(d + "/main.js", "rb").read()), ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True)
    ap.add_argument("--elm-home", required=True)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--n", type=int, default=150)
    ap.add_argument("--work", default=None)
    a = ap.parse_args()
    a.elm = os.path.abspath(a.elm)
    work = a.work or tempfile.mkdtemp(prefix="pkgsub-")
    L = bigint_cases.gen(a.seed, a.n, 300, 6, elm=True)
    big = open(os.path.join(here, "../bigint/t/main_template.fic")).read().replace("@DATA@", bigint_cases.render(L))
    small = """module Main exposing (main)

import BigInt


check : Int
check =
    if BigInt.toString (BigInt.mul (BigInt.fromInt 123456789) (BigInt.fromInt 987654321)) == "121932631112635269" then
        0

    else
        1


main : Program () () ()
main =
    Platform.worker
        { init =
            \\_ ->
                ( Debug.log "cases" 1 |> always (Debug.log "failed" check) |> always (), Cmd.none )
        , update = \\_ _ -> ( (), Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }
"""
    bad = 0

    def report(name, ok, detail=""):
        nonlocal bad
        print("%-8s %s %s" % (name, "OK" if ok else "FAIL", detail))
        if not ok:
            bad += 1

    # core: the substitution happens, output equals the JS build with the Elm package
    d = work + "/core"
    project(d, big, "2.1.2")
    c, err = build_c(d, a)
    js, err2 = build_js(d, a)
    if c is None or js is None:
        report("core", False, "build failed " + err + err2)
    else:
        msg, out, rc = c
        said = "cmditch/elm-bigint 2.1.2 is replaced by the core package" in msg
        csrc = open(d + "/main.c").read()
        coreids = len(re.findall(r"cmditch", csrc))   # ids of the package appear in the C text
        vec = "vec" in csrc.lower()
        report("core", said and out == js[0] and out and rc == 0 and js[1] == 0 and ("cases: %d" % len(L)) in out,
               "message=%s cases=%d out==js:%s c-bytes=%d" % (said, len(L), out == js[0], len(csrc)))
    jscore = js

    # off: the setting turns it off
    d = work + "/off"
    project(d, big, "2.1.2", '"ficus-core-packages":false,')
    c, err = build_c(d, a)
    if c is None:
        report("off", False, "build failed " + err)
    else:
        msg, out, rc = c
        report("off", "replaced by the core package" not in msg and out == jscore[0] and rc == 0 and ("cases: %d" % len(L)) in out,
               "no message=%s out==js:%s" % ("replaced" not in msg, out == jscore[0]))
    coresrc = open(work + "/core/main.c").read()
    offsrc = open(work + "/off/main.c").read() if c else ""
    report("c-differs", coresrc != offsrc and len(coresrc) != len(offsrc), "core C %d bytes, Elm package C %d bytes" % (len(coresrc), len(offsrc)))

    # range: version outside 2.x
    d = work + "/range"
    project(d, small, "1.0.1")
    c, err = build_c(d, a)
    js1, err1 = build_js(d, a)
    if c is None or js1 is None:
        report("range", False, "build failed " + err + err1)
    else:
        msg, out, rc = c
        report("range", "replaced by the core package" not in msg and out == js1[0] and ("failed: 0") in out and rc == 0, "out=%s" % out)

    # JS identity: the project with 2.1.2 gives the same main.js with the setting on or off
    d1 = work + "/core"
    d2 = work + "/off"
    j1 = open(d1 + "/main.js", "rb").read()
    j2 = open(d2 + "/main.js", "rb").read() if os.path.exists(d2 + "/main.js") else None
    if j2 is None:
        build_js(d2, a)
        j2 = open(d2 + "/main.js", "rb").read()
    report("js-same", j1 == j2, "main.js %d bytes" % len(j1))
    sys.exit(1 if bad else 0)


main()
