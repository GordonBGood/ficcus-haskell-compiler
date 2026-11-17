#!/usr/bin/env python3
"""FIX2 step 3: differential test of the offset based String functions (slice, left, right, dropLeft, dropRight, indexes, contains,
startsWith, endsWith, length) on random strings and random indices.

  python3 ficcus-tests/stringdiff.py --elm bin/elmficNN --safe tools/safe --elm-home H [--seeds 6] [--cases 300] [--elm0193 bin/elm0193]

For each seed a program is generated whose cases are random strings (ASCII only, then accents and symbols of two and three UTF-8 bytes, then
characters outside the BMP) with random indices (in range, out of range, negative) and patterns cut out of the string. Three results must agree:
  * the model below (Python's str is a sequence of code points: decision L11, `String.length "😀"` is 1),
  * the Ficcus C program, --no-rc and --rc (gcc, with ASan/UBSan under --san),
  * for the programs without characters outside the BMP: Elm 0.19.3 compiled to JavaScript and run under node (there UTF-16 units and code
    points are the same, so this is the differential test against Elm). With characters outside the BMP Elm counts two units for one and can
    cut a surrogate pair; Ficcus does not (L11), so there the model is the reference and the cases with such characters are not run on Elm.
Exit status 1 on any difference. The work directory is a temporary directory that is removed at the end."""
import argparse, os, random, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
RT = os.path.join(ROOT, "targets", "c")

ALPHABETS = {
    "ascii": list("abc  ab"),
    "bmp": list("abcé  ñß€日本語é"),
    "astral": list("abcé 日😀😣a😀"),
}


def model(s, a, b, sub):
    n = len(s)
    def sl(f, t):
        if f < 0: f = max(f + n, 0)
        elif f > n: f = n
        if t < 0: t = max(t + n, 0)
        elif t > n: t = n
        return s[f:t] if f < t else ""
    idx, i = [], 0
    if sub:
        while True:
            i = s.find(sub, i)
            if i < 0: break
            idx.append(i); i += len(sub)
    return "|".join([
        sl(a, b), "" if a < 1 else sl(0, a), "" if a < 1 else sl(-a, n), s if a < 1 else sl(a, n), s if a < 1 else sl(0, -a),
        ",".join(map(str, idx)), str(sub in s), str(s.startswith(sub)), str(s.endswith(sub)), str(n)])


def gen(seed, cases, kind):
    r = random.Random(seed)
    alpha = ALPHABETS[kind]
    out = []
    for _ in range(cases):
        s = "".join(r.choice(alpha) for _ in range(r.choice([0, 1, 2, 3, 5, 8, 12, 20, 40])))
        n = len(s)
        a, b = r.randint(-n - 2, n + 2), r.randint(-n - 2, n + 2)
        if s and r.random() < 0.7:
            i = r.randint(0, n - 1); j = r.randint(i, min(n, i + r.choice([1, 1, 2, 3, 5])))
            sub = s[i:j]
        else:
            sub = "".join(r.choice(alpha) for _ in range(r.choice([0, 1, 2])))
        out.append((s, a, b, sub))
    return out


def program(cases):
    rows = "\n    ".join("%s { s = \"%s\", a = %d, b = %d, sub = \"%s\" }" % ("[" if i == 0 else ",", s, a, b, sub) for i, (s, a, b, sub) in enumerate(cases))
    return '''module Strdiff exposing (main)


cases : List { s : String, a : Int, b : Int, sub : String }
cases =
    %s
    ]


one : { s : String, a : Int, b : Int, sub : String } -> String
one { s, a, b, sub } =
    String.join "|"
        [ String.slice a b s
        , String.left a s
        , String.right a s
        , String.dropLeft a s
        , String.dropRight a s
        , String.join "," (List.map String.fromInt (String.indexes sub s))
        , if String.contains sub s then "True" else "False"
        , if String.startsWith sub s then "True" else "False"
        , if String.endsWith sub s then "True" else "False"
        , String.fromInt (String.length s)
        ]


main : Program () () ()
main =
    Platform.worker
        { init =
            \\_ ->
                let
                    l = List.indexedMap (\\i c -> Debug.log (String.fromInt i) (one c)) cases
                in
                if List.length l > 0 then
                    ( (), Cmd.none )

                else
                    ( (), Cmd.none )
        , update = \\_ m -> ( m, Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }
''' % rows.lstrip()


def expected(cases):
    # Elm's left/right/dropLeft/dropRight (core String.elm): left n s = if n < 1 then "" else slice 0 n s; right n s = if n < 1 then "" else slice -n (length s) s;
    # dropLeft n s = if n < 1 then s else slice n (length s) s; dropRight n s = if n < 1 then s else slice 0 -n s
    return "".join("%d: \"%s\"\n" % (i, model(s, a, b, sub)) for i, (s, a, b, sub) in enumerate(cases))


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, **kw)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--safe", required=True); ap.add_argument("--elm-home", required=True)
    ap.add_argument("--elm0193", default=os.path.join(ROOT, "bin", "elm0193"))
    ap.add_argument("--seeds", type=int, default=6); ap.add_argument("--cases", type=int, default=300)
    ap.add_argument("--san", action="store_true"); ap.add_argument("--no-elm", action="store_true")
    a = ap.parse_args()
    env = dict(os.environ, ELM_HOME=os.path.abspath(a.elm_home))
    work = tempfile.mkdtemp(prefix="strdiff.", dir=os.environ.get("TMPDIR"))
    bad = 0
    try:
        for seed in range(a.seeds):
            kind = ["ascii", "bmp", "astral"][seed % 3]
            cs = gen(seed, a.cases, kind)
            want = expected(cs)
            d = os.path.join(work, "p%d" % seed)
            os.makedirs(os.path.join(d, "src"))
            shutil.copy(os.path.join(HERE, "initlazy", "elm.json"), d)
            open(os.path.join(d, "src", "Strdiff.fic"), "w", encoding="utf-8").write(program(cs))
            for mode in ("--no-rc", "--rc"):
                p = run([os.path.abspath(a.safe), os.path.abspath(a.elm), "make", "src/Strdiff.fic", "--output=x.c", mode], cwd=d, env=env)
                if p.returncode != 0:
                    print("FAIL seed %d %s: compiler: %s" % (seed, mode, (p.stdout + p.stderr).decode()[-300:])); bad += 1; continue
                flags = ["-DFIC_STATS", "-DFIC_RC"] if mode == "--rc" else []
                if a.san and mode == "--rc": flags += ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-g", "-DFIC_NO_POOL"]
                b = run(["gcc", "-std=c99", "-O2", "-ffp-contract=off", "-w"] + flags + ["-I", RT, os.path.join(d, "x.c"), "-o", os.path.join(d, "x"), "-lm"])
                if b.returncode != 0:
                    print("FAIL seed %d %s: gcc %s" % (seed, mode, b.stderr.decode()[-300:])); bad += 1; continue
                r = run([os.path.join(d, "x")])
                got = r.stdout.decode("utf-8", "replace")
                if r.returncode != 0 or got != want:
                    bad += 1
                    gl, wl = got.splitlines(), want.splitlines()
                    k = next((i for i in range(min(len(gl), len(wl))) if gl[i] != wl[i]), min(len(gl), len(wl)))
                    print("FAIL seed %d (%s) %s: exit %d, first difference at line %d\n  case %r\n  got  %s\n  want %s" % (
                        seed, kind, mode, r.returncode, k, cs[k] if k < len(cs) else None, gl[k] if k < len(gl) else "<missing>", wl[k] if k < len(wl) else "<missing>"))
                else:
                    print("ok   seed %d (%s, %d cases) Ficcus C %s" % (seed, kind, a.cases, mode))
            if kind != "astral" and not a.no_elm:
                shutil.copy(os.path.join(d, "src", "Strdiff.fic"), os.path.join(d, "src", "Strdiff.elm"))
                p = run([a.elm0193, "make", "src/Strdiff.elm", "--output=o.js"], cwd=d, env=env)
                if p.returncode != 0:
                    print("FAIL seed %d: Elm 0.19.3: %s" % (seed, (p.stdout + p.stderr).decode()[-300:])); bad += 1; continue
                js = ("var fs=require('fs'),vm=require('vm');var c={console:console,setTimeout:setTimeout,clearTimeout:clearTimeout};c.window=c;vm.createContext(c);"
                      "vm.runInContext(fs.readFileSync('o.js','utf8'),c);c.Elm.Strdiff.init();")
                r = run(["node", "-e", js], cwd=d)
                got = r.stdout.decode("utf-8", "replace")
                if got != want:
                    bad += 1; print("FAIL seed %d (%s): Elm 0.19.3 under node differs from the model (the model is wrong)" % (seed, kind))
                else:
                    print("ok   seed %d (%s) Elm 0.19.3 under node equals the model" % (seed, kind))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("stringdiff: %s" % ("all agree" if bad == 0 else "%d FAILURES" % bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
