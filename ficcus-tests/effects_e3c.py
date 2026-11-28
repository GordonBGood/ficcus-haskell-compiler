#!/usr/bin/env python3
"""Effects slices E3c and E3d (docs/E3-PORTS-DESIGN.md D5, D6, D9, D10) and the E3a review's F2 (docs/E3A-REVIEW.md): the payload
types of Ficcus at the host interface (sized integers with range checks, Word64 to 2^64 - 1, Float32, Vector as an array and as a raw
vector) and very deep values.

Programs in ficcus-tests/effects3c/src/*.fic; the runtime cases run as in effects_e3.py (its `check`, with this directory's programs and
host: effects3c/host/host_api.c is a script driven host of the value API, FIC_HOST_SCRIPT=effects3c/scripts/<case>.script). Kinds:
  twin   the expected output is Elm's: the Elm twin of the program (this program with Array for Vector, Int for the sized integers and
         Float for Float32, `twin` below) compiled by the reference compiler and run under node with effects3/ref/run3.js, on inputs
         that are in range and exact in JavaScript; --goldens writes it
  hand   no Elm behaviour (range refusals, raw vectors, JUINT, depth): the expected files were checked by hand line by line against the
         design note (the reasons are in docs/E3C-NOTES.md section 4) and are not regenerated
Compile cases (`COMPILE`) compare the compiler's report: an `.elm` module keeps Elm's payload error (twin: the same module given to
the reference compiler, with a project module `Int8` that is a custom type, so that both report the same type), and a build to
JavaScript of a `.fic` program with a Ficcus payload is refused (hand).

  python3 ficcus-tests/effects_e3c.py --elm bin/elmficNN --elm-home H [--only a,b]        exit 1 on any failure
  python3 ficcus-tests/effects_e3c.py --goldens --ref bin/elm0193 --elm-home H [--only a,b]
  python3 ficcus-tests/effects_e3c.py --elm bin/elmficNN --elm-home H --timing 100000000   the Vector Word8 round trip (informational)"""
import argparse, os, re, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import effects_e3 as e3                                       # noqa: E402

E3C = os.path.join(HERE, "effects3c")
S = os.path.join(E3C, "scripts")
HS = lambda name: {"FIC_HOST_SCRIPT": os.path.join(S, name + ".script")}
IN = lambda name: {"FIC_PORTS_IN": os.path.join(S, name + ".in")}

TESTS = {
    "c_sized": ("E3cSized", "runner", IN("sized"), "twin",
                "D5: every sized type and Float32 in and out at its edges, alone and in a record (Maybe, List, tuple)"),
    "c_sized_crash": ("E3cSized", "runner", IN("sized_crash"), "hand", "D5: Int8 128 from the runner: crash 4 with the range text"),
    "c_sized_edges": ("E3cSized", "api", HS("sized_edges"), "hand",
                      "D5: Int8 -129 128, Word8 256 -1, Word64 2^63 2^64-1 2^64 -1, NaN, Float32 overflow, through the API and text"),
    "c_vector": ("E3cVector", "runner", IN("vector"), "twin",
                 "D6, D9: Vector of Int, Float, Word8, Int16, Float32, Word64, String, records, Maybe (Vector Word8) in and out"),
    "c_vector_crash": ("E3cVector", "runner", IN("vector_crash"), "hand", "D6: Vector Word8 [1, 256]: crash 4 at json[1]"),
    "c_vector_raw": ("E3cVector", "api", HS("vector_raw"), "hand",
                     "D9, D10: raw vectors of every kind, zero copy (same memory) for 8 byte kinds, kind mismatch, 1 MB Word8 round trip"),
    "c_deep": ("E3cDeep", "api", HS("deep"), "hand",
               "F2: 10,000 and 1,000,000 levels: to_json, from_json, send, send_json, Json.Value with a JUINT or raw leaf, refusal text"),
}

# compile cases: (source file in effects3c/compile, extra project files, output flag, kind, what)
COMPILE = {
    "c_elm_port_int8": ("ElmPortInt8.elm", ["Int8.elm"], "--output=/dev/null", "twin",
                        "D6: an .elm module keeps Elm's checkPayload: a port of the overlay's Int8 gets Elm's error text"),
    "c_fic_port_dict": ("FicPortDict.fic", [], "--output=/dev/null", "twin",
                        "D6: a .fic module: Dict (and custom types) stay refused with Elm's text"),
    "c_fic_js": ("FicPortJs.fic", [], "--output=out.js", "hand",
                 "D6: the JavaScript build of a .fic program with a Ficcus payload is refused (no overlay module Int8)"),
}

SIZED = ["Int8", "Int16", "Int32", "Word8", "Word16", "Word32", "Word64"]


def twin(src):
    """the Elm twin of a test program: Array for Vector, Int for the sized integers, Float for Float32"""
    s = re.sub(r"^import (%s|Float32) exposing \(\w+\)\n" % "|".join(SIZED), "", src, flags=re.M)
    s = s.replace("import Vector exposing (Vector)", "import Array exposing (Array)")
    s = re.sub(r"\b(%s)\.toString\b" % "|".join(SIZED), "String.fromInt", s)
    s = re.sub(r"\bFloat32\.toString\b", "String.fromFloat", s)
    s = re.sub(r"\b(%s)\.(toInt|fromInt)\b" % "|".join(SIZED), "identity", s)
    s = re.sub(r"\bFloat32\.(toFloat|fromFloat)\b", "identity", s)
    s = re.sub(r"\bVector\.", "Array.", s)
    s = re.sub(r"\bVector\b", "Array", s)
    s = re.sub(r"\b(%s)\b" % "|".join(SIZED), "Int", s)
    return re.sub(r"\bFloat32\b", "Float", s)


def gen(tmp):
    pass


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, **kw)


def goldens(a, names):
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    proj = os.path.join(tmp, "ref"); os.makedirs(os.path.join(proj, "src"))
    shutil.copy(os.path.join(E3C, "elm.json"), proj)
    bad, built = 0, {}
    for n in names:
        if n in COMPILE:
            src, extra, out, kind, _ = COMPILE[n]
            if kind != "twin": print("hand   %s (expected written by hand, not regenerated)" % n); continue
            p = os.path.join(tmp, "c_" + n); os.makedirs(os.path.join(p, "src"))
            shutil.copy(os.path.join(E3C, "elm.json"), p)
            for f in [src] + extra:
                shutil.copy(os.path.join(E3C, "compile", f), os.path.join(p, "src", f.replace(".fic", ".elm")))
            r = run([os.path.abspath(a.ref), "make", "src/" + src.replace(".fic", ".elm"), out], cwd=p, env=dict(os.environ, ELM_HOME=a.elm_home))
            open(os.path.join(HERE, "expected", "e3_" + n + ".report"), "w").write(norm(r.stdout.decode() + r.stderr.decode()))
            print("golden %s: exit %d" % (n, r.returncode))
            continue
        prog, mode, env, kind, _ = TESTS[n]
        if kind != "twin":
            print("hand   %s (expected written by hand, not regenerated)" % n); continue
        if prog not in built:
            open(os.path.join(proj, "src", prog + ".elm"), "w").write(twin(open(os.path.join(E3C, "src", prog + ".fic")).read()))
            js = os.path.join(tmp, prog + ".js")
            p = run([os.path.abspath(a.ref), "make", "src/%s.elm" % prog, "--output=" + js], cwd=proj, env=dict(os.environ, ELM_HOME=a.elm_home))
            if p.returncode != 0:
                print("FAIL %s: the reference compiler: %s" % (prog, (p.stdout + p.stderr).decode()[-800:])); bad += 1; continue
            built[prog] = js
        e = {k: v for k, v in os.environ.items() if k not in ("FIC_FLAGS", "FIC_FLAGS_FILE", "FIC_PORTS_IN", "FIC_HOST_SCRIPT")}
        r = run(["node", os.path.join(HERE, "effects3", "ref", "run3.js"), built[prog], prog], env=dict(e, TZ="UTC", **env), timeout=600)
        b = os.path.join(HERE, "expected", "e3_" + n)
        open(b + ".out", "w").write(r.stdout.decode())
        open(b + ".err", "w").write(r.stderr.decode())
        open(b + ".code", "w").write("%d\n" % r.returncode)
        print("golden %s: %d lines, exit %d" % (n, r.stdout.decode().count("\n"), r.returncode))
    shutil.rmtree(tmp, ignore_errors=True)
    return bad


def norm(text):
    """a compiler report without the parts that differ between the two compilers (the file extension, the build progress lines)"""
    text = re.sub(r"\.fic\b", ".elm", text).replace("\r", "\n")
    lines = [l.rstrip() for l in text.split("\n")]
    lines = [l for l in lines if not re.match(r"^(Compiling|Success|Dependencies|Starting|Verifying|Building)", l.strip())]
    while lines and lines[0] == "": lines.pop(0)
    return "\n".join(l.strip() if l.strip().startswith("Detected problems") else l for l in lines)


def compile_cases(a, names):
    bad = 0
    for n in names:
        src, extra, out, kind, what = COMPILE[n]
        tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
        os.makedirs(os.path.join(tmp, "src"))
        shutil.copy(os.path.join(E3C, "elm.json"), tmp)
        shutil.copy(os.path.join(E3C, "compile", src), os.path.join(tmp, "src", src))
        flags = [out] if out != "--output=/dev/null" else ["--output=" + os.path.join(tmp, "out.c")]
        r = run([os.path.abspath(a.elm), "make", "src/" + src, *flags], cwd=tmp, env=dict(os.environ, ELM_HOME=a.elm_home))
        got = norm(r.stdout.decode() + r.stderr.decode())
        want = open(os.path.join(HERE, "expected", "e3_" + n + ".report")).read()
        ok = r.returncode != 0 and got == want
        print(("ok   " if ok else "FAIL ") + "%s: %s" % (n, "report = Elm" if kind == "twin" else "report = expected")
              + ("" if ok else "  exit %d\n--- got\n%s\n--- want\n%s" % (r.returncode, got[-1500:], want[-1500:])))
        bad += 0 if ok else 1
        shutil.rmtree(tmp, ignore_errors=True)
    return bad


def timing(a, n):
    """the Vector Word8 round trip of n bytes through the API, gcc -O2 --rc, FIC_TIMING (informational; not a check)"""
    tmp = tempfile.mkdtemp(dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    d = os.path.join(tmp, "p"); shutil.copytree(E3C, d, ignore=shutil.ignore_patterns("elm-stuff"))
    c = os.path.join(tmp, "E3cVector.c")
    p = run([os.path.abspath(a.elm), "make", "src/E3cVector.fic", "--output=" + c, "--rc"], cwd=d, env=dict(os.environ, ELM_HOME=a.elm_home))
    if p.returncode != 0: print(p.stdout.decode()[-800:]); return 1
    exe = os.path.join(tmp, "t")
    b = run(["gcc", "-std=c99", "-ffp-contract=off", "-w", "-O2", "-DFIC_RC", "-I", e3.RT, c, os.path.join(E3C, "host", "host_api.c"),
             "-DFIC_HOST_MAIN=api_main", "-o", exe, "-lm"])
    if b.returncode != 0: print(b.stderr.decode()[-800:]); return 1
    script = os.path.join(tmp, "t.script")
    open(script, "w").write("bytes vbIn %d\n" % n)
    r = run([exe], env=dict(os.environ, FIC_HOST_SCRIPT=script, FIC_TIMING="1"), timeout=600)
    print(r.stdout.decode().splitlines()[-1] if r.stdout else "", "|", r.stderr.decode().strip())
    shutil.rmtree(tmp, ignore_errors=True)
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm"); ap.add_argument("--elm-home", required=True)
    ap.add_argument("--goldens", action="store_true"); ap.add_argument("--ref")
    ap.add_argument("--only"); ap.add_argument("--keep", action="store_true")
    ap.add_argument("--timing", type=int)
    a = ap.parse_args()
    if a.timing: return timing(a, a.timing)
    pick = lambda d: [n for n in d if not a.only or n in a.only.split(",")]
    if a.goldens:
        bad = goldens(a, pick(TESTS) + pick(COMPILE))
    else:
        e3.TESTS, e3.E3, e3.gen = TESTS, E3C, gen         # effects_e3's runner, host and checks, on this directory
        bad = e3.check(a, pick(TESTS)) + compile_cases(a, pick(COMPILE))
    print("effects_e3c: %s" % ("%d failures" % bad if bad else "all ok"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
