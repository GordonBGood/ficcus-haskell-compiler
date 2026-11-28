#!/usr/bin/env python3
"""fuzz.py -- random differential test of the sized integers and Float32 against the Python model (sizedmodel.py).
One program per seed: random expression trees (depth <= 3) over every type, compiled with --output=x.c, run, compared line by line.
  python3 ficus-tests/sized/fuzz.py --elm bin/elmficN1 --seeds 200 [--first 1] [-j 2] [--cc gcc|clang] [--keep]
Exit status 1 when any seed differs (the program and both outputs of the first failing seeds are kept in the scratch directory)."""
import argparse, concurrent.futures as cf, json, os, random, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from sizedmodel import *

def root():
    d = HERE
    while d != os.path.dirname(d):
        if os.path.isdir(os.path.join(d, "targets", "c")) and os.path.isdir(os.path.join(d, "bin")): return d
        d = os.path.dirname(d)
    sys.exit("workspace root not found")
ROOT = root()

def wrap64(x):
    x &= (1 << 64) - 1
    return x - (1 << 64) if x >= (1 << 63) else x

def lit(t, v):
    v = t.toint(v) if not t.isfloat else v
    return str(v) if v >= 0 else "(%d)" % v

def gen_int(rng, t, depth, vars):
    M = t.name
    if depth == 0 or rng.random() < 0.2:
        if rng.random() < 0.55:
            n, v = rng.choice(vars); return n, v
        v = rng.choice([rng.choice(boundary(t)), t.wrap(rng.getrandbits(64))])
        if t.name == "Word64" and v >= 1 << 63: v = v >> 1                   # a literal is an Int
        return lit(t, v), v
    sub = lambda: gen_int(rng, t, depth - 1, vars)
    op = rng.choice(["add", "sub", "mul", "pow", "idiv", "mod", "rem", "and", "or", "xor", "neg", "abs", "not", "shl", "shr", "if", "max", "min", "conv", "pop", "cmpn"])
    if op in ("add", "sub", "mul", "idiv"):
        (a, x), (b, y) = sub(), sub()
        sym = {"add": "+", "sub": "-", "mul": "*", "idiv": "//"}[op]
        return "(%s %s %s)" % (a, sym, b), getattr(t, op)(x, y)
    if op == "pow":
        (a, x), (b, y) = sub(), sub()
        return "(%s ^ %s)" % (a, b), t.pow(x, y)
    if op in ("mod", "rem"):
        (a, x), (b, y) = sub(), sub()
        return "(%s %s %s)" % ("modBy" if op == "mod" else "remainderBy", a, b), getattr(t, op)(x, y)
    if op in ("and", "or", "xor"):
        (a, x), (b, y) = sub(), sub()
        return "(%s.%s %s %s)" % (M, op, a, b), getattr(t, op + "_" if op != "xor" else "xor")(x, y)
    if op == "neg": a, x = sub(); return "(negate %s)" % a, t.neg(x)
    if op == "abs": a, x = sub(); return "(abs %s)" % a, t.abs(x)
    if op == "not": a, x = sub(); return "(%s.complement %s)" % (M, a), t.complement(x)
    if op in ("shl", "shr"):
        a, x = sub(); n = rng.randint(-3, t.bits + 5)
        return "(%s.%s (%d) %s)" % (M, "shiftLeftBy" if op == "shl" else "shiftRightBy", n, a), (t.shl if op == "shl" else t.shr)(n, x)
    if op in ("max", "min"):
        (a, x), (b, y) = sub(), sub()
        return "(%s %s %s)" % (op, a, b), (max if op == "max" else min)(x, y)
    if op == "conv":                                                         # through Int: toInt, an Int operation (wraps at 64 bits), fromInt
        a, x = sub(); k = rng.choice([1, 3, 255, 65537, 1 << 40, -7]); w = t.toint(x)
        return "(%s.fromInt (%s.toInt %s * %d + 1))" % (M, M, a, k), t.fromint(wrap64(w * k + 1))
    if op == "pop":
        a, x = sub()
        return "(%s.fromInt (%s.popCount %s))" % (M, M, a), t.fromint(t.popcount(x))
    if op == "cmpn":                                                         # a comparison chooses between two values
        (a, x), (b, y), (c, z), (d, w) = sub(), sub(), sub(), sub()
        cmp = rng.choice(["<", "<=", ">", ">=", "==", "/="])
        res = {"<": x < y, "<=": x <= y, ">": x > y, ">=": x >= y, "==": x == y, "/=": x != y}[cmp]
        return "(if id%s %s %s %s then %s else %s)" % (M, a, cmp, b, c, d), z if res else w
    # if: on the order of two values
    (a, x), (b, y), (c, z) = sub(), sub(), sub()
    return "(if compare (id%s %s) %s == LT then %s else %s)" % (M, a, b, c, b), z if x < y else y

def gen_f32(rng, depth, vars):
    t = BY_NAME["Float32"]
    if depth == 0 or rng.random() < 0.2:
        if rng.random() < 0.6:
            n, v = rng.choice(vars); return n, v
        v = rng.choice([np.float32(rng.choice([0.1, 0.5, 1.0, 3.0, 100.0, 1e10, 1e-10, 16777216.0, 3.4e38])),
                        np.float32(rng.uniform(-1000, 1000))])
        return "(Float32.fromFloat %s)" % repr(float(v)).replace("e+", "e"), v
    sub = lambda: gen_f32(rng, depth - 1, vars)
    op = rng.choice(["add", "sub", "mul", "div", "neg", "abs", "conv", "int"])
    if op in ("add", "sub", "mul", "div"):
        (a, x), (b, y) = sub(), sub()
        sym = {"add": "+", "sub": "-", "mul": "*", "div": "/"}[op]
        return "(%s %s %s)" % (a, sym, b), getattr(t, op)(x, y)
    if op == "neg": a, x = sub(); return "(negate %s)" % a, t.neg(x)
    if op == "abs": a, x = sub(); return "(abs %s)" % a, t.abs(x)
    if op == "conv": a, x = sub(); return "(Float32.fromFloat (Float32.toFloat %s * 3.0))" % a, f32(float(x) * 3.0)
    n = rng.choice([1, 7, -3, 16777217, 123456789])
    a, x = sub()
    return "(%s + Float32.fromInt %d)" % (a, n), t.add(x, t.fromint(n))

def program(seed):
    rng = random.Random(seed)
    lines_elm, expected, defs, imports = [], [], [], []
    for t in INTS + [BY_NAME["Float32"]]:
        M = t.name
        imports.append("import %s exposing (%s)" % (M, M))
        defs.append("id%s : %s -> %s\nid%s x =\n    x\n" % (M, M, M, M))
        vars = []
        for i in range(4):
            if t.isfloat:
                v = rng.choice(fvals()[:21] + [np.float32(rng.uniform(-100, 100))])
                lit_s = "(0 / 0)" if v != v else "(1 / 0)" if np.isinf(v) and v > 0 else "(-1 / 0)" if np.isinf(v) else repr(float(v)).replace("e+", "e")
                defs.append("v%s%d : %s\nv%s%d =\n    %s.fromFloat %s\n" % (M, i, M, M, i, M, lit_s))
                if v == v: vars.append(("v%s%d" % (M, i), v))
            else:
                v = rng.choice([rng.choice(boundary(t)), t.wrap(rng.getrandbits(64))])
                defs.append("v%s%d : %s\nv%s%d =\n    %s.fromInt %s\n" % (M, i, M, M, i, M, lit(t, v)))
                vars.append(("v%s%d" % (M, i), v))
        for k in range(14):
            e, v = gen_f32(rng, 3, vars) if t.isfloat else gen_int(rng, t, 3, vars)
            lines_elm.append("%s.toString %s" % (M, e))
            expected.append(t.tostr(v))
    src = "module Main exposing (main)\n\n" + "\n".join(imports) + "\n\n\n" + "\n\n".join(defs) + """

logAll : List String -> ()
logAll items =
    List.foldl (\\s acc -> let _ = Debug.log "r" s in acc) () items


main : Program () () ()
main =
    Platform.worker
        { init =
            \\_ ->
                let
                    _ =
                        logAll
""" + "\n".join("                            %s %s" % ("[" if i == 0 else ",", e) for i, e in enumerate(lines_elm)) + """
                            ]
                in
                ( (), Cmd.none )
        , update = \\_ m -> ( m, Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }
"""
    return src, expected

def run_seed(seed, elm, home, cc, keep):
    src, expected = program(seed)
    work = tempfile.mkdtemp(prefix="szfuzz-", dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    try:
        os.makedirs(os.path.join(work, "src"))
        open(os.path.join(work, "src", "Main.elm"), "w").write(src)
        json.dump({"type": "application", "source-directories": ["src"], "elm-version": "0.19.3",
                   "dependencies": {"direct": {"elm/core": "1.0.5"}, "indirect": {"elm/json": "1.1.3"}}, "test-dependencies": {"direct": {}, "indirect": {}}},
                  open(os.path.join(work, "elm.json"), "w"))
        env = dict(os.environ, ELM_HOME=home)
        p = subprocess.run([elm, "make", "src/Main.elm", "--output=x.c", "--no-rc"], cwd=work, env=env, capture_output=True, text=True)
        if p.returncode != 0: return seed, "compile failed: " + (p.stdout + p.stderr)[-600:], work
        b = subprocess.run([cc, "-std=c99", "-w", "-ffp-contract=off", "-O1", "-I", os.path.join(ROOT, "targets", "c"), "x.c", "-o", "x", "-lm"], cwd=work, capture_output=True, text=True)
        if b.returncode != 0: return seed, "cc failed: " + b.stderr[-600:], work
        r = subprocess.run(["./x"], cwd=work, capture_output=True, text=True, timeout=60)
        got = [l[4:-1] for l in r.stdout.splitlines()]
        want = expected
        if got != want:
            bad = [(i, g, w) for i, (g, w) in enumerate(zip(got, want)) if g != w][:3]
            return seed, "output differs (%d lines got, %d expected), first: %r" % (len(got), len(want), bad), work
        return seed, None, work
    finally:
        pass

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--seeds", type=int, default=200); ap.add_argument("--first", type=int, default=1)
    ap.add_argument("-j", type=int, default=2); ap.add_argument("--cc", default="gcc"); ap.add_argument("--keep", action="store_true")
    ap.add_argument("--print", type=int, help="print the program of this seed and exit")
    a = ap.parse_args()
    if a.print is not None:
        print(program(a.print)[0]); return
    elm = os.path.abspath(a.elm)
    home = tempfile.mkdtemp(prefix="szfuzz-home-", dir=os.environ.get("CLAUDE_CODE_TMPDIR"))
    shutil.copytree(os.path.join(ROOT, "elm-home-difftest", "0.19.3"), os.path.join(home, "0.19.3"), copy_function=shutil.copy2)
    fails = 0
    try:
        with cf.ThreadPoolExecutor(a.j) as ex:
            futs = [ex.submit(run_seed, s, elm, home, a.cc, a.keep) for s in range(a.first, a.first + a.seeds)]
            for f in futs:
                seed, err, work = f.result()
                if err: fails += 1; print("seed %d: %s\n  kept: %s" % (seed, err, work)); 
                else:
                    if not a.keep: shutil.rmtree(work, ignore_errors=True)
        print("%d seeds, %d differ" % (a.seeds, fails))
    finally:
        shutil.rmtree(home, ignore_errors=True)
    sys.exit(1 if fails else 0)

if __name__ == "__main__":
    main()
