#!/usr/bin/env python3
"""v2fuzz.py: random programs over the V2 Vector API and element shapes that ficcus-tests/rcfuzz.py does not generate
(map, indexedMap, foldl, foldr, filter, initialize, repeat, singleton, isEmpty, toIndexedList; elements: tuple with a reference,
Maybe, a recursive custom type, a record that holds a vector; case on Vector.get; update lambdas that capture vectors).
Oracle: the --no-rc build. Check: --rc under ASan+UBSan with -DFIC_STATS: same output, exit 0, 0 live.

  python3 ficcus-tests/v2fuzz.py --elm bin/elmficNN --elm-home H [--first 1] [--count 500] [--work DIR] [--keep DIR]
  python3 ficcus-tests/v2fuzz.py --print N                      (the program of seed N)
Written by the review session (docs/review/REVIEW-1.md); adopted in FIX1 (docs/STAGE4-FIX1.md) with the paths made arguments.
H is the ELM_HOME with elm/core (a copy of elm-home-difftest/0.19.3 is fine). A failing seed is kept as DIR/seedN.fic with the reason
in a comment; the exit status is 1 when any program was flagged. Serial, about 1.3 s per program."""
import argparse, os, random, subprocess, sys, shutil, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
def _root():
    for base in (HERE, os.path.dirname(os.path.realpath(__file__))):
        d = base
        while d != os.path.dirname(d):
            if os.path.isdir(os.path.join(d, "targets", "c")) and os.path.isdir(os.path.join(d, "bin")): return d
            d = os.path.dirname(d)
    sys.exit("workspace root (targets/c and bin) not found")
W = _root()
ELM = None          # set by main
S = None            # work directory
HOME = None         # ELM_HOME

PRELUDE = '''module Main exposing (main)

import Vector exposing (Vector)


type Shape
    = Dot
    | Line String
    | Box Shape Shape


type alias Rec =
    { a : Int, s : String, xs : List Int }


type alias Wrap =
    { k : Int, v : Vector String }


twice : (Int -> a) -> ( a, a )
twice f =
    ( f 1, f 2 )


flip2 : Shape -> Shape
flip2 c =
    case c of
        Box a b ->
            Box b a

        Line s ->
            Line (s ++ "'")

        Dot ->
            Line "d"


depth : Shape -> Int
depth c =
    case c of
        Box a b ->
            1 + depth a + depth b

        _ ->
            0


gVS : Vector String
gVS =
    Vector.fromList [ "g0", "g1", "g2" ]


gVV : Vector (Vector String)
gVV =
    Vector.repeat 2 gVS


mkVS : Int -> Vector String
mkVS n =
    Vector.initialize n (\\k -> "s" ++ String.fromInt k)


mkVI : Int -> Vector Int
mkVI n =
    Vector.initialize n (\\k -> k * 3)


mkVR : Int -> Vector Rec
mkVR n =
    Vector.initialize n (\\k -> { a = k, s = "r" ++ String.fromInt k, xs = [ k ] })


mkVV : Int -> Vector (Vector String)
mkVV n =
    Vector.initialize n mkVS


mkVT : Int -> Vector ( String, Int )
mkVT n =
    Vector.indexedMap (\\i s -> ( s, i )) (mkVS n)


mkVM : Int -> Vector (Maybe String)
mkVM n =
    Vector.initialize n
        (\\k ->
            if modBy 2 k == 0 then
                Just ("m" ++ String.fromInt k)

            else
                Nothing
        )


mkVC : Int -> Vector Shape
mkVC n =
    Vector.initialize n (\\k -> Box (Line (String.fromInt k)) Dot)


mkVW : Int -> Vector Wrap
mkVW n =
    Vector.initialize n (\\k -> { k = k, v = mkVS k })
'''

PARAMS = [("vs", "VS"), ("vi", "VI"), ("vr", "VR"), ("vv", "VV"), ("vt", "VT"), ("vm", "VM"), ("vc", "VC"), ("vw", "VW"), ("n", "Int"), ("s", "Str")]
TY = {"VS": "Vector String", "VI": "Vector Int", "VR": "Vector Rec", "VV": "Vector (Vector String)", "VT": "Vector ( String, Int )",
      "VM": "Vector (Maybe String)", "VC": "Vector Shape", "VW": "Vector Wrap", "Int": "Int", "Str": "String"}
VECS = ["VS", "VI", "VR", "VV", "VT", "VM", "VC", "VW"]
ELEM = {"VS": "Str", "VI": "Int", "VR": "Rec", "VV": "VS", "VT": "Tup", "VM": "May", "VC": "Shp", "VW": "Wrp"}


class G:
    def __init__(self, seed):
        self.r = random.Random(seed); self.n = 0

    def fresh(self):
        self.n += 1; return "x%d" % self.n

    def vars(self, t, env):
        return [v for v, tt in env if tt == t]

    def idx(self, env, d, ind, m=4):
        c = self.r.randint(0, 5)
        if c == 0: return "(%s - 1)" % self.gen("Int", env, d - 1, ind + 8)
        if c == 1: return str(self.r.randint(0, 3))
        return "(modBy %d %s)" % (m, self.gen("Int", env, d - 1, ind + 8))

    def let(self, t, env, d, ind):
        v = self.fresh(); t2 = self.r.choice(VECS + ["Str"])
        e = self.gen(t2, env, d - 1, ind + 12)
        b = self.gen(t, env + [(v, t2)] * 3, d - 1, ind + 8)
        p = " " * ind
        return "\n%s(let\n%s    %s =\n%s        %s\n%sin\n%s%s\n%s)" % (p, p, v, p, e, p, p, b, p)

    def caseget(self, t, env, d, ind):
        vt = self.r.choice(VECS); et = ELEM[vt]; v = self.gen(vt, env, d - 1, ind + 8); x = self.fresh(); p = " " * ind
        i = self.idx(env, d, ind)
        envx = env + ([(x, et)] * 3 if et in TY or et in ("Str", "Int") else [])
        if et == "VS": envx = env + [(x, "VS")] * 3
        return "\n" + p + "(case Vector.get %s %s of\n%s    Just %s ->\n%s        %s\n\n%s    Nothing ->\n%s        %s\n%s)" % (
            i, v, p, x, p, self.gen(t, envx, d - 1, ind + 8), p, p, self.gen(t, env, d - 1, ind + 8), p)

    def lam(self, x, xt, t, env, d, ind):
        # body of a lambda with x : xt in scope (x may be an element type that only some productions use)
        return self.gen(t, env + ([(x, xt)] * 4 if xt in TY else []), d - 1, ind + 8)

    def gen(self, t, env, d, ind):
        r = self.r; g = lambda tt: self.gen(tt, env, d - 1, ind + 8)
        vs = self.vars(t, env)
        if d <= 0 or (vs and r.random() < 0.3):
            if vs: return r.choice(vs)
            return {"Int": str(r.randint(0, 5)), "Str": '"k%d"' % r.randint(0, 9), "VS": "(mkVS 2)", "VI": "(mkVI 3)", "VR": "(mkVR 2)",
                    "VV": "(mkVV 3)", "VT": "(mkVT 2)", "VM": "(mkVM 3)", "VC": "(mkVC 2)", "VW": "(mkVW 3)"}[t]
        if t in TY and r.random() < 0.10: return self.let(t, env, d, ind)
        if t in TY and r.random() < 0.10: return self.caseget(t, env, d, ind)
        if t in VECS and r.random() < 0.06:
            return "(if %s > 2 then %s else %s)" % (g("Int"), g(t), g(t))
        if t in VECS and r.random() < 0.05:
            k = self.fresh()
            return "(Tuple.%s (twice (\\%s -> %s)))" % (r.choice(["first", "second"]), k, self.lam(k, "Int", t, env, d, ind))
        if t in VECS:
            et = ELEM[t]; c = r.randint(0, 9)
            if c == 0: return "(Vector.swap %s %s %s)" % (self.idx(env, d, ind), self.idx(env, d, ind), g(t))
            if c == 1: return "(Vector.slice %s %s %s)" % (self.idx(env, d, ind), self.idx(env, d, ind, 6), g(t))
            if c == 2: return "(Vector.append %s %s)" % (g(t), g(t))
            if c == 3:
                x = self.fresh()
                return "(Vector.filter (\\%s -> %s) %s)" % (x, self.pred(x, et, env, d, ind), g(t))
            if c == 4: return "(Vector.push %s %s)" % (self.elem(et, env, d, ind), g(t))
            if c == 5: return "(Vector.set %s %s %s)" % (self.idx(env, d, ind), self.elem(et, env, d, ind), g(t))
            if c == 6:
                x = self.fresh()
                return "(Vector.update %s (\\%s -> %s) %s)" % (self.idx(env, d, ind), x, self.upd(x, et, env, d, ind), g(t))
            if c == 7:
                x = self.fresh()
                return "(Vector.map (\\%s -> %s) %s)" % (x, self.upd(x, et, env, d, ind), g(t))
            if c == 8:
                k = r.randint(0, 3)
                if k == 0: return "(Vector.repeat %s %s)" % (self.idx(env, d, ind), self.elem(et, env, d, ind))
                if k == 1: return "(Vector.singleton %s)" % self.elem(et, env, d, ind)
                if k == 2: return "(Vector.fromList [ %s, %s, %s ])" % (self.elem(et, env, d, ind), self.elem(et, env, d, ind), self.elem(et, env, d, ind))
                x = self.fresh()
                return "(Vector.initialize %s (\\%s -> %s))" % (self.idx(env, d, ind), x, self.elem(et, env + [(x, "Int")] * 3, d, ind))
            # type specific
            if t == "VS":
                k = r.randint(0, 5); x = self.fresh(); y = self.fresh()
                if k == 0: return "(Maybe.withDefault Vector.empty (Vector.get %s %s))" % (self.idx(env, d, ind), g("VV"))
                if k == 1: return "(Vector.map String.fromInt %s)" % g("VI")
                if k == 2: return "(Vector.map Tuple.first %s)" % g("VT")
                if k == 3: return "(Vector.foldl (\\%s %s -> Vector.append %s %s) Vector.empty %s)" % (x, y, y, x, g("VV"))
                if k == 4: return "(Vector.map (Maybe.withDefault %s) %s)" % (g("Str"), g("VM"))
                return "(Vector.foldr (\\%s %s -> Vector.append %s %s.v) %s %s)" % (x, y, y, x, g("VS"), g("VW"))
            if t == "VI":
                x = self.fresh()
                return r.choice(["(Vector.map String.length %s)" % g("VS"), "(Vector.map Vector.length %s)" % g("VV"),
                                 "(Vector.map depth %s)" % g("VC"), "(Vector.map .k %s)" % g("VW"),
                                 "(Vector.indexedMap (\\%s _ -> %s * 2) %s)" % (x, x, g(r.choice(VECS)))])
            if t == "VT":
                x = self.fresh(); y = self.fresh()
                return r.choice(["(Vector.indexedMap (\\%s %s -> ( %s, %s )) %s)" % (x, y, y, x, g("VS")),
                                 "(Vector.fromList (List.map (\\( %s, %s ) -> ( %s, %s )) (Vector.toIndexedList %s)))" % (x, y, y, x, g("VS"))])
            if t == "VM":
                return r.choice(["(Vector.map Just %s)" % g("VS"), "(Vector.map (Maybe.map (\\w -> w ++ %s)) %s)" % (g("Str"), g("VM"))])
            if t == "VV":
                return r.choice(["(Vector.map .v %s)" % g("VW"), "(Vector.map Vector.singleton %s)" % g("VS"),
                                 "(Vector.map (\\w -> Vector.slice 0 %s w) %s)" % (self.idx(env, d, ind), g("VV"))])
            if t == "VW":
                x = self.fresh(); y = self.fresh()
                return "(Vector.indexedMap (\\%s %s -> { k = %s, v = %s }) %s)" % (x, y, x, y, g("VV"))
            if t == "VC":
                return r.choice(["(Vector.map Line %s)" % g("VS"), "(Vector.map flip2 %s)" % g("VC")])
            return g(t)
        if t == "Int":
            c = r.randint(0, 7); x = self.fresh(); y = self.fresh()
            if c == 0: return str(r.randint(0, 7))
            if c == 1: return "(Vector.length %s)" % g(r.choice(VECS))
            if c == 2: return "(%s + %s)" % (g("Int"), g("Int"))
            if c == 3: return "(Vector.foldl (\\%s %s -> %s + String.length %s) 0 %s)" % (x, y, y, x, g("VS"))
            if c == 4: return "(Vector.foldr (\\%s %s -> %s + %s.a + List.length %s.xs) 1 %s)" % (x, y, y, x, x, g("VR"))
            if c == 5: return "(Maybe.withDefault 7 (Vector.get %s %s))" % (self.idx(env, d, ind), g("VI"))
            if c == 6: return "(if Vector.isEmpty %s then 1 else 0)" % g(r.choice(VECS))
            return "(String.length %s)" % g("Str")
        if t == "Str":
            c = r.randint(0, 6); x = self.fresh(); y = self.fresh()
            if c == 0: return '"q%d"' % r.randint(0, 9)
            if c == 1: return "(%s ++ %s)" % (g("Str"), g("Str"))
            if c == 2: return "(Maybe.withDefault \"none\" (Vector.get %s %s))" % (self.idx(env, d, ind), g("VS"))
            if c == 3: return "(Vector.foldr (\\%s %s -> %s ++ %s) \"\" %s)" % (x, y, y, x, g("VS"))
            if c == 4: return "(String.fromInt %s)" % g("Int")
            if c == 5: return "(Debug.toString %s)" % g(r.choice(VECS))
            return "(Vector.foldl (\\( %s, _ ) %s -> %s ++ %s) \"t\" %s)" % (x, y, x, y, g("VT"))
        raise ValueError(t)

    def elem(self, et, env, d, ind):
        g = lambda tt: self.gen(tt, env, d - 1, ind + 8); r = self.r
        if et in ("Str", "Int", "VS"): return g(et)
        if et == "Rec": return "{ a = %s, s = %s, xs = [ %s ] }" % (g("Int"), g("Str"), g("Int"))
        if et == "Tup": return "( %s, %s )" % (g("Str"), g("Int"))
        if et == "May": return r.choice(["Nothing", "(Just %s)" % g("Str")])
        if et == "Shp": return r.choice(["Dot", "(Line %s)" % g("Str"), "(Box (Line %s) Dot)" % g("Str")])
        if et == "Wrp": return "{ k = %s, v = %s }" % (g("Int"), g("VS"))
        raise ValueError(et)

    def upd(self, x, et, env, d, ind):
        r = self.r
        if et in ("Str", "Int", "VS"): return self.lam(x, et, et, env, d, ind)
        g = lambda tt: self.gen(tt, env, d - 1, ind + 8)
        if et == "Rec": return r.choice(["{ %s | a = %s.a + 1, xs = %s :: %s.xs }" % (x, x, g("Int"), x), "{ %s | s = %s.s ++ %s }" % (x, x, g("Str")),
                                         "{ a = %s, s = %s.s, xs = [] }" % (g("Int"), x)])
        if et == "Tup": return r.choice(["( Tuple.first %s ++ %s, Tuple.second %s + 1 )" % (x, g("Str"), x), "( %s, Tuple.second %s )" % (g("Str"), x)])
        if et == "May": return r.choice(["Maybe.map (\\w -> w ++ %s) %s" % (g("Str"), x), "Nothing", "Just (Maybe.withDefault %s %s)" % (g("Str"), x)])
        if et == "Shp": return r.choice(["Box %s %s" % (x, x), "flip2 %s" % x, "Box (Line %s) %s" % (g("Str"), x)])
        if et == "Wrp": return r.choice(["{ %s | v = Vector.push %s %s.v }" % (x, g("Str"), x), "{ %s | k = %s.k + Vector.length %s.v }" % (x, x, x),
                                         "{ %s | v = Vector.update 0 (\\w -> w ++ %s) %s.v }" % (x, g("Str"), x), "{ k = %s, v = Vector.append %s.v %s }" % (g("Int"), x, g("VS"))])
        raise ValueError(et)

    def pred(self, x, et, env, d, ind):
        k = self.gen("Int", env, d - 1, ind + 8)
        return {"Str": "String.length %s > %s" % (x, k), "Int": "%s > %s" % (x, k), "VS": "Vector.length %s > %s" % (x, k),
                "Rec": "%s.a > %s" % (x, k), "Tup": "Tuple.second %s > %s" % (x, k), "May": "%s /= Nothing" % x,
                "Shp": "depth %s > %s" % (x, k), "Wrp": "Vector.length %s.v > %s" % (x, k)}[et]

    def program(self):
        out = [PRELUDE]; r = self.r; names = []
        for k in range(r.randint(2, 4)):
            t = r.choice(VECS + VECS + ["Str", "Int"]); nm = "f%d" % k; names.append(nm)
            env = [(v, tt) for v, tt in PARAMS] * 2
            sig = " -> ".join(TY[tt] for _, tt in PARAMS) + " -> " + TY[t]
            out.append("\n\n%s : %s\n%s %s =\n    %s\n" % (nm, sig, nm, " ".join(v for v, _ in PARAMS), self.gen(t, env, r.randint(2, 5), 8)))
        lines = []
        for nm in names:
            lines.append('Debug.log "%s fresh" (Debug.toString (%s (mkVS 3) (mkVI 4) (mkVR 3) (mkVV 3) (mkVT 3) (mkVM 4) (mkVC 3) (mkVW 3) 2 "p"))' % (nm, nm))
            lines.append('Debug.log "%s shared" (Debug.toString ( %s aS aI aR aV aT aM aC aW 3 "q", %s gVS aI aR gVV aT aM aC aW 1 "r" ))' % (nm, nm, nm))
        lines.append('Debug.log "kept" (Debug.toString ( ( aS, aI, aR ), ( aV, aT, aM ), ( aC, aW, gVV ) ))')
        out.append('''

results : List String
results =
    let
        aS =
            mkVS 4

        aI =
            mkVI 3

        aR =
            mkVR 3

        aV =
            mkVV 3

        aT =
            mkVT 3

        aM =
            mkVM 3

        aC =
            mkVC 3

        aW =
            mkVW 3
    in
    [ %s
    ]


main : Program () () ()
main =
    Platform.worker
        { init =
            \\_ ->
                if List.length results > 0 then
                    ( (), Cmd.none )

                else
                    ( (), Cmd.none )
        , update = \\_ m -> ( m, Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }
''' % "\n    , ".join(lines))
        return "".join(out)


def run(seed, keep):
    w = os.path.join(S, "work"); shutil.rmtree(w, ignore_errors=True); os.makedirs(w + "/src")
    src = G(seed).program()
    open(w + "/src/Main.fic", "w").write(src)
    open(w + "/elm.json", "w").write('{"type":"application","source-directories":["src"],"elm-version":"0.19.3","dependencies":{"direct":{"elm/core":"1.0.5"},"indirect":{"elm/json":"1.1.3"}},"test-dependencies":{"direct":{},"indirect":{}}}')
    env = dict(os.environ, ELM_HOME=HOME)
    def fail(why):
        open(os.path.join(keep, "seed%d.fic" % seed), "w").write("-- " + why.replace("\n", "\n-- ") + "\n" + src)
        return why.splitlines()[0][:150]
    for mode in ("--no-rc", "--rc"):
        p = subprocess.run([ELM, "make", "src/Main.fic", "--output=%s.c" % mode[2:], mode], cwd=w, env=env, capture_output=True, text=True)
        if p.returncode != 0:
            msg = (p.stdout + p.stderr)
            return ("GEN " if mode == "--no-rc" else "") + fail("compile %s: %s" % (mode, msg[-1500:]))
    cf = ["gcc", "-std=c99", "-O1", "-ffp-contract=off", "-w", "-I", W + "/targets/c"]
    b = subprocess.run(cf + ["no-rc.c", "-o", "norc", "-lm"], cwd=w, capture_output=True, text=True)
    if b.returncode: return fail("cc norc: " + b.stderr[-800:])
    b = subprocess.run(cf + ["-DFIC_STATS", "-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-g", "-DFIC_NO_POOL", "rc.c", "-o", "rcsan", "-lm"], cwd=w, capture_output=True, text=True)
    if b.returncode: return fail("cc rc: " + b.stderr[-800:])
    try:
        o = subprocess.run(["./norc"], cwd=w, capture_output=True, timeout=60)
        if o.returncode != 0: return "GEN " + fail("oracle exit %d: %s" % (o.returncode, o.stderr.decode()[-300:]))
        q = subprocess.run(["./rcsan"], cwd=w, capture_output=True, timeout=120)
    except subprocess.TimeoutExpired:
        return "GEN " + fail("timeout")
    err = q.stderr.decode("utf-8", "replace")
    if q.returncode != 0: return fail("rc exit %d: %s" % (q.returncode, err[-2500:]))
    if q.stdout != o.stdout: return fail("output differs")
    if " live 0 " not in err: return fail("live objects: " + err[-300:])
    return None


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm"); ap.add_argument("--elm-home"); ap.add_argument("--first", type=int, default=1); ap.add_argument("--count", type=int, default=500)
    ap.add_argument("--work"); ap.add_argument("--keep"); ap.add_argument("--print", type=int, dest="show")
    a = ap.parse_args()
    if a.show is not None:
        print(G(a.show).program()); sys.exit(0)
    if not a.elm or not a.elm_home: ap.error("--elm and --elm-home are required")
    ELM = os.path.abspath(a.elm); HOME = os.path.abspath(a.elm_home)
    S = os.path.abspath(a.work) if a.work else tempfile.mkdtemp(prefix="v2fuzz-")
    keep = os.path.abspath(a.keep) if a.keep else os.path.join(S, "keep")
    os.makedirs(S, exist_ok=True); os.makedirs(keep, exist_ok=True)
    bad = 0
    for seed in range(a.first, a.first + a.count):
        why = run(seed, keep)
        if why: bad += 1; print("seed %d: %s" % (seed, why), flush=True)
        if (seed - a.first + 1) % 25 == 0: print("... %d done, %d flagged" % (seed - a.first + 1, bad), flush=True)
    print("done: %d programs, %d flagged (kept in %s)" % (a.count, bad, keep))
    sys.exit(1 if bad else 0)
