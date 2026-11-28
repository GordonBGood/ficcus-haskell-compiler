#!/usr/bin/env python3
"""Effects slices E3a and E3b (docs/E3-PORTS-DESIGN.md): the host interface of ports (D1 to D4, D6 Array, D7, D8, D12) and flags (D11).

Programs in ficus-tests/effects3/src/*.fic are also the Elm references. A case runs a program in one of three ways:
  runner  the generated program alone: the test runner prints the outgoing ports and sends FIC_PORTS_IN (as effects_e2.py)
  host    linked with effects3/host/host3.c (-DFIC_HOST_MAIN): the commands of FIC_HOST_SCRIPT through the public API (subscribe,
          unsubscribe, callbacks that send or unsubscribe themselves, sends whose failure is caught and printed)
  api     linked with effects3/host/host_api.c: the value API and the port calls (C only)
and with the flags of FIC_FLAGS / FIC_FLAGS_FILE. --goldens compiles each program with the reference compiler and runs it under node
with effects3/ref/run3.js, which does the same as the runner or host3.c with Elm's `app.ports` (crash 4 patched to print
errorToString, the text Ficus gives); it writes expected/e3_<case>.out, .err and .code. Cases marked "hand" have no Elm behaviour
(C only, or a recorded deviation): their expected files are written by hand from the design note and are not regenerated.
A check compiles each program --rc (gcc -O2, ASan + UBSan without the pool, -DFIC_DROP_ALL) and --no-rc (-O2), runs every case and
compares stdout, stderr (without the FIC_STATS and FIC_DROP_ALL lines) and the exit status; under --rc a run that ends normally must
have live 0, and FIC_DROP_ALL 0 bad, 0 live after the free.

  python3 ficus-tests/effects_e3.py --elm bin/elmficNN --elm-home H [--only a,b]          exit 1 on any failure
  python3 ficus-tests/effects_e3.py --goldens --ref bin/elm0193 --elm-home H [--only a,b]  writes expected/e3_*"""
import argparse, json, os, re, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
E3 = os.path.join(HERE, "effects3")
RT = os.path.join(HERE, "..", "..", "targets", "c")
RUNTIME = os.path.join(HERE, "..", "runtime")
SAN = ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-g", "-DFIC_NO_POOL", "-Wno-maybe-uninitialized"]
S = os.path.join(E3, "scripts")
REC = json.dumps({"name": "né", "ids": [3, 1, 2], "opt": 2.5, "pair": [7, "seven"], "arr": [True, False],
                  "raw": {"b": [1, {"c": None}], "a": 1.5, "1": "one"}, "sub": {"on": True}, "extra": 0})


def rec(**change):
    r = json.loads(REC)
    for k, v in change.items():
        if v is None: r.pop(k, None)
        else: r[k] = v
    return json.dumps(r)


HS = lambda name: {"FIC_HOST_SCRIPT": os.path.join(S, name + ".script")}
# case: (program, mode, environment, "elm" or "hand", what it tests)
TESTS = {
    "array": ("E3Array", "runner", {"FIC_PORTS_IN": "{GEN}/array.in"}, "elm",
              "D6: Array in and out, empty to 32803 elements (shift 15), records, nested Arrays, Floats; == with Elm's own arrays"),
    "errors": ("E3Errors", "host", HS("E3Errors"), "elm",
               "D7: errorToString of every decoder (Maybe, tuples, records in Elm's field order, Array, nested), caught by the host"),
    "errors_runner": ("E3Errors", "runner", {"FIC_PORTS_IN": os.path.join(S, "errors_runner.in")}, "elm",
                      "D7: the runner's crash 4 (stdout up to the failure, exit 1, errorToString on stderr)"),
    "reentry": ("E3Reentry", "host", HS("E3Reentry"), "elm",
                "D12: a callback that sends at once, one that unsubscribes itself, subscribe during a delivery (both cases)"),
    "reentry_unitflags": ("E3Reentry", "host", dict(HS("E3Reentry"), FIC_FLAGS='{"x":1}'), "elm", "D11: () flags are never read"),
    "flagsint_ok": ("E3FlagsInt", "runner", {"FIC_FLAGS": "42"}, "elm", "D11: Int flags, no managers"),
    "flagsint_1e3": ("E3FlagsInt", "runner", {"FIC_FLAGS": "1e3"}, "elm", "D11: an Int given as 1e3"),
    "flagsint_null": ("E3FlagsInt", "runner", {"FIC_FLAGS": "null"}, "elm", "D11: crash 2 for null"),
    "flagsint_wrong": ("E3FlagsInt", "runner", {"FIC_FLAGS": '"x"'}, "elm", "D11: crash 2 for a string"),
    "flagsint_missing": ("E3FlagsInt", "runner", {}, "elm", "D11: absent flags are undefined: crash 2"),
    "flagsint_file": ("E3FlagsInt", "runner", {"FIC_FLAGS_FILE": os.path.join(S, "flags42.json")}, "elm", "D11: FIC_FLAGS_FILE"),
    "flagsint_both": ("E3FlagsInt", "runner", {"FIC_FLAGS": "42", "FIC_FLAGS_FILE": os.path.join(S, "flags42.json")}, "hand",
                      "D11 (user): both variables set: refused with a message, exit 1"),
    "flagsint_badjson": ("E3FlagsInt", "runner", {"FIC_FLAGS": "{4"}, "hand", "D11: FIC_FLAGS that is not JSON: a message, exit 1"),
    "flagsint_host": ("E3FlagsInt", "host", {"FIC_FLAGS": "7"}, "elm", "D11: fic_app_start with a value"),
    "flagsint_host_missing": ("E3FlagsInt", "host", {}, "elm", "D11: fic_app_start(NULL) returns FIC_E_DECODE with crash 2's text"),
    "flagsrec_ok": ("E3FlagsRec", "runner", {"FIC_FLAGS": REC}, "elm", "D11: record flags of every kind, sent back through a port"),
    "flagsrec_nofield": ("E3FlagsRec", "runner", {"FIC_FLAGS": rec(ids=None)}, "elm", "D11: a missing field"),
    "flagsrec_deep": ("E3FlagsRec", "runner", {"FIC_FLAGS": rec(sub={"on": 1})}, "elm", "D11: a nested field of the wrong type"),
    "flagsrec_arr": ("E3FlagsRec", "runner", {"FIC_FLAGS": rec(arr=[True, 3])}, "elm", "D11: an Array element"),
    "flagsrec_missing": ("E3FlagsRec", "runner", {}, "elm", "D11: absent record flags"),
    "flagsvalue_ok": ("E3FlagsValue", "runner", {"FIC_FLAGS": '{"b":[1,{"c":null}],"a":1.5,"2":true}'}, "elm", "D11: Json.Value flags"),
    "flagsvalue_missing": ("E3FlagsValue", "runner", {}, "hand",
                           "D11 deviation: absent Json.Value flags; Elm passes undefined into the program, Ficus refuses to start"),
    "flagsmaybe_null": ("E3FlagsMaybe", "runner", {"FIC_FLAGS": "null"}, "elm", "D11: Maybe flags, null"),
    "flagsmaybe_5": ("E3FlagsMaybe", "runner", {"FIC_FLAGS": "5"}, "elm", "D11: Maybe flags, 5"),
    "flagsmaybe_missing": ("E3FlagsMaybe", "runner", {}, "elm", "D11: Maybe flags absent: oneOf's two failures with undefined"),
    "api": ("E3Api", "api", {}, "hand", "D2-D4, D7, D8, D15: the value API, codes and texts, ownership (live 0), after the end"),
    # the E2 review's rejects X1 to X3 (compile errors until E3), now run
    # E3a review F1: List payloads whose cells nothing else in the program builds (did not compile: needObj missing in portDecBody)
    "listport_ok": ("R3PortList", "runner", {"FIC_PORTS_IN": os.path.join(S, "R3PortListOk.in")}, "elm",
                    "F1: List String on an incoming port (the review's reproducer R3PortList)"),
    "listport": ("R3PortList", "runner", {"FIC_PORTS_IN": os.path.join(S, "R3PortList.in")}, "elm",
                 "F1: List String on an incoming port; then a value that does not fit (crash 4)"),
    "listflags_string": ("R3FlagsList", "runner", {"FIC_FLAGS": '["ab","c\\u00e9",""]'}, "elm", "F1: List String flags"),
    "listflags_string_empty": ("R3FlagsList", "runner", {"FIC_FLAGS": "[]"}, "elm", "F1: List String flags, empty"),
    "listflags_string_wrong": ("R3FlagsList", "runner", {"FIC_FLAGS": '["a",1]'}, "elm", "F1: List String flags, crash 2 at [1]"),
    "listflags_maybeint": ("E3FlagsListMaybeInt", "runner", {"FIC_FLAGS": "[1,null,-3]"}, "elm", "F1: List (Maybe Int) flags"),
    "listflags_maybeint_wrong": ("E3FlagsListMaybeInt", "runner", {"FIC_FLAGS": '[1,"x"]'}, "elm", "F1: List (Maybe Int), oneOf at [1]"),
    "listflags_maybestr": ("E3FlagsListMaybeStr", "runner", {"FIC_FLAGS": '["a\\u00e9",null,""]'}, "elm", "F1: List (Maybe String) flags"),
    "listflags_maybestr_wrong": ("E3FlagsListMaybeStr", "runner", {"FIC_FLAGS": "[null,5]"}, "elm", "F1: List (Maybe String), oneOf at [1]"),
    "listflags_nested": ("E3FlagsListNested", "runner", {"FIC_FLAGS": "[[1,2],[],[3]]"}, "elm", "F1: List (List Int) flags"),
    "listflags_nested_wrong": ("E3FlagsListNested", "runner", {"FIC_FLAGS": '[[1],[2,"x"]]'}, "elm", "F1: List (List Int), crash 2 at [1][1]"),
    "x1flags": ("X1Flags", "runner", {"FIC_FLAGS": "5"}, "elm", "E2 review X1: Int flags"),
    "x1flags_missing": ("X1Flags", "runner", {}, "elm", "E2 review X1: Int flags, none given"),
    "x1flagsstring": ("X1FlagsString", "runner", {"FIC_FLAGS": r'"h\u00e9llo \ud83d\ude00"'}, "elm", "E2 review X1: String flags"),
    "x2arrayportout": ("X2ArrayPortOut", "runner", {}, "elm", "E2 review X2: an outgoing Array"),
    "x3arrayportin": ("X3ArrayPortIn", "runner", {"FIC_PORTS_IN": os.path.join(S, "X3ArrayPortIn.in")}, "elm",
                      "E2 review X3: a record with an Array field, then a value that does not fit"),
}


def gen(tmp):
    """the generated inputs (the large Array script)"""
    lines = ["arrIn " + json.dumps(list(range(n)), separators=(",", ":")) for n in (0, 1, 32, 33, 1056, 1057, 32803)]
    lines += ['recsIn [{"name":"p","id":1,"extra":true},{"id":2,"name":"q\\u00e9"}]', 'nestIn [[], ["a", null], [null]]',
              'floatsIn [1, 2.5, -0, 1e300, 3, 0.1]']
    open(os.path.join(tmp, "array.in"), "w").write("\n".join(lines) + "\n")


def envOf(env, tmp):
    return {k: v.replace("{GEN}", tmp) for k, v in env.items()}


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, **kw)


def clean_err(err):
    return "".join(l for l in err.splitlines(True) if not l.startswith(("FIC_STATS", "FIC_DROP_ALL")))


def expected(name):
    b = os.path.join(HERE, "expected", "e3_" + name)
    return open(b + ".out").read(), open(b + ".err").read(), int(open(b + ".code").read())


def goldens(a, names):
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    gen(tmp)
    proj = os.path.join(tmp, "ref"); os.makedirs(os.path.join(proj, "src"))
    shutil.copy(os.path.join(E3, "elm.json"), proj)
    bad, built = 0, {}
    for n in names:
        prog, mode, env, kind, _ = TESTS[n]
        if kind == "hand" or mode == "api":
            print("hand   %s (expected written by hand, not regenerated)" % n); continue
        if prog not in built:
            shutil.copy(os.path.join(E3, "src", prog + ".fic"), os.path.join(proj, "src", prog + ".elm"))
            js = os.path.join(tmp, prog + ".js")
            p = run([os.path.abspath(a.ref), "make", "src/%s.elm" % prog, "--output=" + js], cwd=proj, env=dict(os.environ, ELM_HOME=a.elm_home))
            if p.returncode != 0:
                print("FAIL %s: the reference compiler: %s" % (prog, (p.stdout + p.stderr).decode()[-600:])); bad += 1; continue
            built[prog] = js
        e = {k: v for k, v in os.environ.items() if k not in ("FIC_FLAGS", "FIC_FLAGS_FILE", "FIC_PORTS_IN", "FIC_HOST_SCRIPT")}
        r = run(["node", os.path.join(E3, "ref", "run3.js"), built[prog], prog], env=dict(e, TZ="UTC", **envOf(env, tmp)), timeout=600)
        b = os.path.join(HERE, "expected", "e3_" + n)
        open(b + ".out", "w").write(r.stdout.decode())
        open(b + ".err", "w").write(r.stderr.decode())
        open(b + ".code", "w").write("%d\n" % r.returncode)
        print("golden %s: %d lines, exit %d" % (n, r.stdout.decode().count("\n"), r.returncode))
    shutil.rmtree(tmp, ignore_errors=True)
    return bad


def check(a, names):
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    gen(tmp)
    d = os.path.join(tmp, "effects3"); shutil.copytree(E3, d, ignore=shutil.ignore_patterns("elm-stuff", "ref"))
    bad = 0

    def report(ok, what, detail=""):
        nonlocal bad
        print(("ok   " if ok else "FAIL ") + what + ("" if ok else "  " + detail)); bad += 0 if ok else 1

    exes = {}                                    # (program, mode, flag) -> [(tag, exe)] or None

    def build(prog, mode, flag):
        key = (prog, mode, flag)
        if key in exes: return exes[key]
        out = os.path.join(tmp, prog + flag)
        os.makedirs(out, exist_ok=True)
        c = os.path.join(out, prog + ".c")
        if not os.path.exists(c):
            p = run([os.path.abspath(a.elm), "make", "src/%s.fic" % prog, "--output=" + c, flag], cwd=d, env=dict(os.environ, ELM_HOME=a.elm_home))
            if p.returncode != 0:
                report(False, "%s %s compiles" % (prog, flag), (p.stdout + p.stderr).decode()[-600:]); exes[key] = None; return None
        extra = {"runner": [], "host": [os.path.join(E3, "host", "host3.c"), "-DFIC_HOST_MAIN=fic_test_host_main", "-I", RUNTIME],
                 "api": [os.path.join(E3, "host", "host_api.c"), "-DFIC_HOST_MAIN=api_main", "-I", out]}[mode]
        res = []
        for tag, cf in ((("O2", ["-O2"]), ("san", SAN), ("dropall", ["-O1", "-DFIC_DROP_ALL"])) if flag == "--rc" else (("O2", ["-O2"]),)):
            exe = os.path.join(out, "%s-%s-%s" % (prog, mode, tag))
            b = run(["gcc", "-std=c99", "-ffp-contract=off", "-w", *cf, "-DFIC_STATS", *(["-DFIC_RC"] if flag == "--rc" else []),
                     "-I", RT, c, *extra, "-o", exe, "-lm"])
            if b.returncode != 0:
                report(False, "%s %s %s %s builds" % (prog, mode, flag, tag), b.stderr.decode()[-600:]); continue
            res.append((tag, exe))
        exes[key] = res
        return res

    base = {k: v for k, v in os.environ.items() if k not in ("FIC_FLAGS", "FIC_FLAGS_FILE", "FIC_PORTS_IN", "FIC_HOST_SCRIPT")}
    for n in names:
        prog, mode, env, kind, what = TESTS[n]
        try:
            want_out, want_err, want_code = expected(n)
        except OSError:
            report(False, "%s: expected files" % n, "missing (run --goldens)"); continue
        for flag in ("--rc", "--no-rc"):
            for tag, exe in build(prog, mode, flag) or []:
                r = run([exe], env=dict(base, TZ="UTC", **envOf(env, tmp)), timeout=600)
                out, err = r.stdout.decode(), r.stderr.decode()
                ok = out == want_out and clean_err(err) == want_err and r.returncode == want_code
                live = re.search(r"FIC_STATS: allocs \d+ live (\d+)", err)
                checks = ""
                if flag == "--rc" and want_code == 0:
                    ok = ok and live is not None and live.group(1) == "0"; checks = ", live 0"
                    if tag == "dropall":
                        ok = ok and re.search(r"FIC_DROP_ALL: \d+ objects checked, 0 bad, 0 live after the free", err) is not None
                report(ok, "%s %s %s: %s%s" % (n, flag, tag, "output = Elm" if kind == "elm" else "output = expected", checks),
                       "exit %d (want %d)\n--- got\n%s\n--- stderr\n%s" % (r.returncode, want_code, out[-1500:], err[-1500:]))
    if not a.keep: shutil.rmtree(tmp, ignore_errors=True)
    else: print("kept " + tmp)
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm"); ap.add_argument("--elm-home", required=True)
    ap.add_argument("--goldens", action="store_true"); ap.add_argument("--ref")
    ap.add_argument("--only"); ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    names = [n for n in TESTS if not a.only or any(o == n for o in a.only.split(","))]
    bad = goldens(a, names) if a.goldens else check(a, names)
    print("effects_e3: %s" % ("%d failures" % bad if bad else "all ok"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
