#!/usr/bin/env python3
"""Fuzz of the Rc pass (STAGE4-PLAN section 10 item 7, section 15): random but valid Elm programs, by construction well typed.

  python3 ficcus-tests/rcfuzz.py --elm bin/elmficNN --elm-home H --safe tools/safe --count 500 [--first 1] [--settings default,proj,reuse]
                                 [--out DIR] [--keep DIR] [--elm-check bin/elm0193]
  python3 ficcus-tests/rcfuzz.py --print 17            (the program of seed 17 on stdout)
  python3 ficcus-tests/rcfuzz.py --replay --elm ... --elm-home H --safe tools/safe   (the kept failing programs, ficcus-tests/rcfuzz/*.fic)

Program number N is made from random.Random(N) alone (fixed seeds: the same N is the same program for ever, as long as this file
does not change). Each program has a fixed prelude (recursive functions on lists and trees, a pair builder, loops) and generated
functions and outputs that use: let, case on lists, trees, tuples, Maybe and Result, closures and partial applications, records and
record updates, self tail calls (loops), strings, and (S6) arrays and dictionaries: Array.set, push, append, slice, map on arrays with
and without a tree, shared and not shared, Dict.insert, update, remove and union, partial applications that hold an array.

For each program:
  1. the no-RC build (`elm make --no-rc`, gcc -O1) is run: its output is the oracle;
  2. for each ownership setting the `--rc` build (the compiler runs RcCheck on it: a rejected program is a failure) is built with
     AddressSanitizer + UBSan (-DFIC_NO_POOL, leak detection on) and -DFIC_STATS and run: the output must equal the oracle's, the
     exit status must be 0, the sanitizers silent, and the run must end with 0 live objects.
A failing program is copied to --keep (default ficcus-tests/rcfuzz/) as seed<N>_<setting>.fic with the reason in a comment line: it
stays as a test case (--replay). Exit status 1 on any failure. Serial; every program run goes through --safe (memory cap, timeout)."""
import argparse, os, random, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SETTINGS = {"default": {}, "proj": {"FICCUS_BORROW_PROJ": "1"}, "reuse": {"FICCUS_BORROW_REUSE": "1"}, "s3rule": {"FICCUS_BORROW_S3": "1"}}

PRELUDE = '''module Main exposing (main)

import Array exposing (Array)
import Dict exposing (Dict)


type Tree
    = Leaf
    | Node Tree Int Tree


type alias Pair =
    ( Int, List Int )


type alias Rec =
    { a : Int, s : String, xs : List Int }


inc : List Int -> List Int
inc xs =
    case xs of
        [] ->
            []

        x :: rest ->
            (x + 1) :: inc rest


keepEven : List Int -> List Int
keepEven xs =
    case xs of
        [] ->
            []

        x :: rest ->
            if modBy 2 x == 0 then
                x :: keepEven rest

            else
                keepEven rest


insert : Int -> Tree -> Tree
insert v t =
    case t of
        Leaf ->
            Node Leaf v Leaf

        Node l x r ->
            if v < x then
                Node (insert v l) x r

            else if v > x then
                Node l x (insert v r)

            else
                Node l x r


fromList : List Int -> Tree
fromList xs =
    List.foldl insert Leaf xs


toList : Tree -> List Int
toList t =
    case t of
        Leaf ->
            []

        Node l x r ->
            toList l ++ (x :: toList r)


treeSum : Tree -> Int
treeSum t =
    case t of
        Leaf ->
            0

        Node l x r ->
            treeSum l + x + treeSum r


sumL : Int -> List Int -> Int
sumL acc xs =
    case xs of
        [] ->
            acc

        x :: rest ->
            sumL (acc + x) rest


joinS : List String -> String
joinS ss =
    List.foldl (\\s acc -> acc ++ s ++ ";") "" ss


add3 : Int -> Int -> Int -> Int
add3 a b c =
    a + 2 * b + 3 * c


splitL : List Int -> Pair
splitL xs =
    List.foldr
        (\\x ( n, es ) ->
            if modBy 2 x == 0 then
                ( n, x :: es )

            else
                ( n + x, es )
        )
        ( 0, [] )
        xs


szB : Bool -> Int
szB b =
    if b then
        1

    else
        0


szM : Maybe Int -> Int
szM m =
    Maybe.withDefault 7 m


szR : Result String Int -> Int
szR r =
    case r of
        Ok v ->
            v

        Err e ->
            String.length e


szP : Pair -> Int
szP ( n, xs ) =
    n + List.length xs


getA : Rec -> Int
getA r =
    r.a


getS : Rec -> String
getS r =
    r.s


getXs : Rec -> List Int
getXs r =
    r.xs


szRec : Rec -> Int
szRec r =
    r.a + String.length r.s + List.length r.xs


-- S6: arrays and dictionaries (updates in place when the value is not shared)
sumArr : Array Int -> Int
sumArr a =
    Array.foldl (+) (Array.length a) a


szArrS : Array String -> Int
szArrS a =
    Array.foldl (\\s n -> n + String.length s + 1) 0 a


szDct : Dict Int Int -> Int
szDct d =
    Dict.foldl (\\k v n -> n + k + v) (Dict.size d) d


setAll : Int -> Array Int -> Array Int
setAll i a =
    if i <= 0 then
        a

    else
        setAll (i - 1) (Array.set (modBy (1 + Array.length a) (i * 7)) i a)


growArr : Int -> Array Int -> Array Int
growArr i a =
    if i <= 0 then
        a

    else
        growArr (i - 1) (Array.push i a)


fillD : Int -> Dict Int Int -> Dict Int Int
fillD i d =
    if i <= 0 then
        d

    else
        fillD (i - 1) (Dict.insert (modBy 13 (i * 5)) i d)


getAt : Array Int -> Int -> Int
getAt a i =
    Maybe.withDefault i (Array.get i a)


putAt : Array Int -> Int -> Int -> Array Int
putAt a i v =
    Array.set i v a


-- a function that is not known here gets its array: a partial application made at run time
bindA : (Array Int -> Int -> Int -> Array Int) -> Array Int -> (Int -> Int -> Array Int)
bindA g a =
    g a


callA : Int -> (Int -> Int -> Array Int) -> Array Int
callA i f =
    f i (i + 1)
'''

TYPES = ["Int", "Str", "Bool", "LInt", "LStr", "Tree", "MInt", "Res", "Pair", "Rec", "Fn", "Arr", "ArrS", "Dct"]
ELM = {"Int": "Int", "Str": "String", "Bool": "Bool", "LInt": "List Int", "LStr": "List String", "Tree": "Tree", "MInt": "Maybe Int",
       "Res": "Result String Int", "Pair": "Pair", "Rec": "Rec", "Fn": "(Int -> Int)", "Arr": "Array Int", "ArrS": "Array String", "Dct": "Dict Int Int"}
SIZE = {"Int": "%s", "Str": "String.length %s", "Bool": "szB %s", "LInt": "List.length %s", "LStr": "String.length (joinS %s)", "Tree": "treeSum %s",
        "MInt": "szM %s", "Res": "szR %s", "Pair": "szP %s", "Rec": "szRec %s", "Fn": "%s 3", "Arr": "sumArr %s", "ArrS": "szArrS %s", "Dct": "szDct %s"}


class Gen:
    def __init__(self, seed):
        self.r = random.Random(seed)
        self.n = 0
        self.funs = []        # (name, [param types], result type)
        self.loops = []       # (name, type)
        self.annotate = True  # every generated let has a type annotation (see --no-annot)

    def fresh(self, p="v"):
        self.n += 1
        return "%s%d" % (p, self.n)

    def pad(self, ind):
        return "\n" + " " * ind

    def leaf(self, t, env):
        r = self.r
        vs = [n for n, vt in env if vt == t]
        if vs and r.random() < 0.7: return r.choice(vs)
        if t == "Int": return str(r.randint(0, 9))
        if t == "Str": return '"%s"' % r.choice(["", "a", "bc", "xyz", "q7"])
        if t == "Bool": return r.choice(["True", "False"])
        if t == "LInt": return r.choice(["[]", "[ 1, 2, 3 ]", "[ 4 ]", "[ 9, 8, 7, 6 ]"])
        if t == "LStr": return r.choice(["[]", '[ "a", "b" ]', '[ "zz" ]'])
        if t == "Tree": return r.choice(["Leaf", "(Node Leaf 5 Leaf)", "(fromList [ 4, 2, 6 ])"])
        if t == "MInt": return r.choice(["Nothing", "(Just 3)"])
        if t == "Res": return r.choice(["(Ok 2)", '(Err "bad")'])
        if t == "Pair": return r.choice(["( 1, [] )", "( 2, [ 5, 6 ] )"])
        if t == "Rec": return r.choice(['{ a = 1, s = "r", xs = [] }', '{ a = 4, s = "", xs = [ 1, 2 ] }'])
        if t == "Fn": return r.choice(["(add3 1 2)", "(\\\\w -> w + 1)".replace("\\\\", "\\")])
        if t == "Arr": return r.choice(["Array.empty", "(Array.fromList [ 1, 2, 3 ])", "(Array.repeat 40 2)", "(Array.initialize 70 identity)"])
        if t == "ArrS": return r.choice(["Array.empty", '(Array.fromList [ "a", "b" ])', '(Array.repeat 35 "s")'])
        if t == "Dct": return r.choice(["Dict.empty", "(Dict.fromList [ ( 1, 2 ), ( 3, 4 ) ])", "(fillD 20 Dict.empty)"])
        raise ValueError(t)

    # an expression of type t; `ind` is the indentation of the line it starts on (continuation lines are indented more)
    def gen(self, t, env, d, ind):
        r = self.r
        if d <= 0 or r.random() < 0.08: return self.leaf(t, env)
        g = lambda tt, e=env, dd=d - 1, i=ind + 8: self.gen(tt, e, dd, i)
        k = r.random()
        if k < 0.34: return self.generic(t, env, d, ind)
        if t == "Int":
            c = r.randint(0, 22)
            # S7 (Ficcus.Mono.Inline): a Maybe or Result made by a small function and matched at once
            if c == 17:
                v = self.fresh()
                return "(case Array.get (modBy 6 %s) %s of\n%sJust %s -> %s\n%sNothing -> %s)" % (
                    g("Int"), g("Arr"), " " * (ind + 8), v, self.gen("Int", env + [(v, "Int")], d - 1, ind + 12), " " * (ind + 8), g("Int"))
            if c == 18:
                v, w = self.fresh(), self.fresh()
                return "(case ( Array.get (modBy 4 %s) %s, Array.get 1 %s ) of\n%s( Just %s, Just %s ) -> %s\n%s_ -> %s)" % (
                    g("Int"), g("Arr"), g("Arr"), " " * (ind + 8), v, w, self.gen("Int", env + [(v, "Int"), (w, "Int")], d - 1, ind + 12), " " * (ind + 8), str(r.randint(0, 9)))
            if c == 19: return "(Maybe.withDefault 2 (Maybe.andThen (\\q -> Array.get q %s) (Array.get (modBy 3 %s) %s)))".replace("\\\\", "\\") % (g("Arr"), g("Int"), g("Arr"))
            if c == 20: return "(Maybe.withDefault 0 (Maybe.map String.length (Array.get (modBy 3 %s) %s)))" % (g("Int"), g("ArrS"))
            if c == 21:
                v = self.fresh()
                return "(case List.head %s of\n%sJust %s -> String.length %s + %s\n%sNothing -> %s)" % (
                    g("LStr"), " " * (ind + 8), v, v, g("Int"), " " * (ind + 8), g("Int"))
            if c == 22: return "(Maybe.withDefault %s (Maybe.map %s (List.head %s)))" % (g("Int"), g("Fn"), g("LInt"))
            if c == 12: return "(sumArr %s)" % g("Arr")
            if c == 13: return "(Maybe.withDefault 0 (Array.get (modBy 5 %s) %s))" % (g("Int"), g("Arr"))
            if c == 14: return "(Dict.size %s)" % g("Dct")
            if c == 15: return "(Maybe.withDefault 1 (Dict.get (modBy 9 %s) %s))" % (g("Int"), g("Dct"))
            if c == 16: return "(szArrS %s)" % g("ArrS")
            if c == 0: return "(%s + %s)" % (g("Int"), g("Int"))
            if c == 1: return "(%s - %s)" % (g("Int"), g("Int"))
            if c == 2: return "(modBy 7 (%s * %s))" % (g("Int"), g("Int"))
            if c == 3: return "(String.length %s)" % g("Str")
            if c == 4: return "(List.length %s)" % g("LInt")
            if c == 5: return "(sumL 0 %s)" % g("LInt")
            if c == 6: return "(treeSum %s)" % g("Tree")
            if c == 7: return "(getA %s)" % g("Rec")
            if c == 8: return "(%s %s)" % (g("Fn"), g("Int"))
            if c == 9:
                x, acc = self.fresh(), self.fresh()
                return "(List.foldl (\\%s %s -> %s) %s %s)" % (x, acc, self.gen("Int", env + [(x, "Int"), (acc, "Int")], d - 1, ind + 8), g("Int"), g("LInt"))
            if c == 10: return "(add3 %s %s %s)" % (g("Int"), g("Int"), g("Int"))
            return "(szM %s)" % g("MInt")
        if t == "Str":
            c = r.randint(0, 5)
            if c == 5: return "(Maybe.withDefault \"none\" (Array.get (modBy 3 %s) %s))" % (g("Int"), g("ArrS"))
            if c == 0: return "(%s ++ %s)" % (g("Str"), g("Str"))
            if c == 1: return "(String.fromInt %s)" % g("Int")
            if c == 2: return "(getS %s)" % g("Rec")
            if c == 3: return "(joinS %s)" % g("LStr")
            return "(%s ++ String.fromInt %s)" % (g("Str"), g("Int"))
        if t == "Bool":
            c = r.randint(0, 5)
            if c == 0: return "(%s < %s)" % (g("Int"), g("Int"))
            if c == 1: return "(%s == %s)" % (g("Int"), g("Int"))
            if c == 2: return "(%s == %s)" % (g("Str"), g("Str"))
            if c == 3: return "(not %s)" % g("Bool")
            if c == 4: return "(%s && %s)" % (g("Bool"), g("Bool"))
            return "(%s || List.isEmpty %s)" % (g("Bool"), g("LInt"))
        if t == "LInt":
            c = r.randint(0, 14)
            if c == 12: return "(Array.toList %s)" % g("Arr")
            if c == 13: return "(Dict.keys %s)" % g("Dct")
            if c == 14: return "(Dict.values %s)" % g("Dct")
            if c == 0: return "(%s :: %s)" % (g("Int"), g("LInt"))
            if c == 1: return "[ %s, %s ]" % (g("Int"), g("Int"))
            if c == 2: return "(List.map %s %s)" % (g("Fn"), g("LInt"))
            if c == 3:
                x = self.fresh()
                return "(List.filter (\\%s -> %s) %s)" % (x, self.gen("Bool", env + [(x, "Int")], d - 1, ind + 8), g("LInt"))
            if c == 4: return "(%s ++ %s)" % (g("LInt"), g("LInt"))
            if c == 5: return "(List.reverse %s)" % g("LInt")
            if c == 6: return "(List.range 0 (modBy 5 %s))" % g("Int")
            if c == 7: return "(inc %s)" % g("LInt")
            if c == 8: return "(keepEven %s)" % g("LInt")
            if c == 9: return "(toList %s)" % g("Tree")
            if c == 10: return "(getXs %s)" % g("Rec")
            return "(inc (inc %s))" % g("LInt")
        if t == "LStr":
            c = r.randint(0, 3)
            if c == 3: return "(Array.toList %s)" % g("ArrS")
            if c == 0: return "(%s :: %s)" % (g("Str"), g("LStr"))
            if c == 1: return "(List.map String.fromInt %s)" % g("LInt")
            return "[ %s, %s ]" % (g("Str"), g("Str"))
        if t == "Tree":
            c = r.randint(0, 3)
            if c == 0: return "(Node %s %s %s)" % (g("Tree"), g("Int"), g("Tree"))
            if c == 1: return "(insert %s %s)" % (g("Int"), g("Tree"))
            if c == 2: return "(fromList %s)" % g("LInt")
            return "(insert %s (insert %s %s))" % (g("Int"), g("Int"), g("Tree"))
        if t == "MInt":
            c = r.randint(0, 4)
            if c == 3: return "(Array.get (modBy 6 %s) %s)" % (g("Int"), g("Arr"))
            if c == 4: return "(Dict.get %s %s)" % (g("Int"), g("Dct"))
            if c == 0: return "(Just %s)" % g("Int")
            if c == 1: return "(List.head %s)" % g("LInt")
            return "(Maybe.map %s %s)" % (g("Fn"), g("MInt"))
        if t == "Res":
            c = r.randint(0, 1)
            if c == 0: return "(Ok %s)" % g("Int")
            return "(Err %s)" % g("Str")
        if t == "Pair":
            c = r.randint(0, 1)
            if c == 0: return "( %s, %s )" % (g("Int"), g("LInt"))
            return "(splitL %s)" % g("LInt")
        if t == "Rec":
            c = r.randint(0, 3)
            if c == 0: return "{ a = %s, s = %s, xs = %s }" % (g("Int"), g("Str"), g("LInt"))
            v = self.fresh()
            e2 = env + [(v, "Rec")]
            if c == 1: upd = lambda i: "{ %s | a = %s }" % (v, self.gen("Int", e2, d - 1, i))
            elif c == 2: upd = lambda i: "{ %s | xs = %s, s = %s }" % (v, self.gen("LInt", e2, d - 1, i), self.gen("Str", e2, d - 1, i))
            else: upd = lambda i: "{ %s | s = %s ++ %s.s, a = %s.a + 1 }" % (v, self.gen("Str", env, d - 1, i), v, v)
            return self.let(v, "Rec", upd, env, d, ind)
        if t == "Arr":
            c = r.randint(0, 10)
            if c == 0: return "(Array.set (modBy 4 %s) %s %s)" % (g("Int"), g("Int"), g("Arr"))
            if c == 1: return "(Array.set (modBy 70 %s) %s %s)" % (g("Int"), g("Int"), g("Arr"))
            if c == 2: return "(Array.push %s %s)" % (g("Int"), g("Arr"))
            if c == 3: return "(Array.map %s %s)" % (g("Fn"), g("Arr"))
            if c == 4: return "(Array.fromList %s)" % g("LInt")
            if c == 5: return "(setAll (modBy 9 %s) %s)" % (g("Int"), g("Arr"))
            if c == 6: return "(Array.append %s %s)" % (g("Arr"), g("Arr"))
            if c == 7: return "(Array.slice 1 (modBy 50 %s) %s)" % (g("Int"), g("Arr"))
            if c == 8: return "(growArr (modBy 40 %s) %s)" % (g("Int"), g("Arr"))
            if c == 9: return "(callA (modBy 3 %s) (bindA putAt %s))" % (g("Int"), g("Arr"))
            return "(Array.set 0 %s (Array.set 1 %s %s))" % (g("Int"), g("Int"), g("Arr"))
        if t == "ArrS":
            c = r.randint(0, 4)
            if c == 0: return "(Array.set (modBy 3 %s) %s %s)" % (g("Int"), g("Str"), g("ArrS"))
            if c == 1: return "(Array.set (modBy 40 %s) %s %s)" % (g("Int"), g("Str"), g("ArrS"))
            if c == 2: return "(Array.push %s %s)" % (g("Str"), g("ArrS"))
            if c == 3: return "(Array.map String.fromInt %s)" % g("Arr")
            return "(Array.fromList %s)" % g("LStr")
        if t == "Dct":
            c = r.randint(0, 5)
            if c == 0: return "(Dict.insert (modBy 9 %s) %s %s)" % (g("Int"), g("Int"), g("Dct"))
            if c == 1: return "(Dict.remove (modBy 9 %s) %s)" % (g("Int"), g("Dct"))
            if c == 2: return "(Dict.update (modBy 9 %s) (Maybe.map %s) %s)" % (g("Int"), g("Fn"), g("Dct"))
            if c == 3: return "(fillD (modBy 30 %s) %s)" % (g("Int"), g("Dct"))
            if c == 4: return "(Dict.union %s %s)" % (g("Dct"), g("Dct"))
            return "(Dict.insert %s %s (Dict.insert %s %s %s))" % (g("Int"), g("Int"), g("Int"), g("Int"), g("Dct"))
        if t == "Fn":
            c = r.randint(0, 4)
            if c == 4: return "(getAt %s)" % g("Arr")
            w = self.fresh()
            if c == 0: return "(\\%s -> %s)" % (w, self.gen("Int", env + [(w, "Int")], d - 1, ind + 8))
            if c == 1: return "(add3 %s %s)" % (g("Int"), g("Int"))
            if c == 2: return "(\\%s -> %s (%s %s))" % (w, g("Fn"), g("Fn"), w)
            return "(\\%s -> %s + List.length %s)" % (w, w, g("LInt"))
        raise ValueError(t)

    # Layout: a multi-line form starts on a new line at column ind + 4 (`base`), so that its bindings and branches (at base + 5) are to
    # the right of its keyword whatever precedes it on the line it is used in; everything inside it is generated with ind >= base + 8.
    def let(self, v, vt, body_of, env, d, ind):
        base = ind + 4
        p = self.pad
        val = self.gen(vt, env, d - 1, base + 8)
        body = body_of(base + 8)
        ann = (p(base + 5) + v + " : " + ELM[vt].strip("()")) if self.annotate else ""
        # a let may be directly an operand of a binary operator (fixed in elmfic56: "internal: no scheme for elm/core:Basics.add" before;
        # the example `letop` is the case)
        return "(" + p(base) + "(let" + ann + p(base + 5) + v + " =" + p(base + 9) + val + p(base + 1) + "in" + p(base + 5) + body + "))"

    # the forms that exist for every type
    def generic(self, t, env, d, ind):
        r, p = self.r, self.pad
        base = ind + 4
        c = r.randint(0, 9)
        b1 = lambda e: self.gen(t, e, d - 1, base + 8)
        sc = lambda tt: self.gen(tt, env, d - 1, base + 8)
        br, bo = p(base + 5), p(base + 9)
        if c == 0:
            return p(base) + "(if %s then" % sc("Bool") + bo + b1(env) + p(base + 1) + "else" + bo + b1(env) + ")"
        if c == 1:
            v, vt = self.fresh(), r.choice(TYPES)
            return self.let(v, vt, lambda i: self.gen(t, env + [(v, vt)], d - 1, i), env, d, ind)
        if c == 2:
            x, rest = self.fresh(), self.fresh()
            return (p(base) + "(case %s of" % sc("LInt") + br + "[] ->" + bo + b1(env)
                    + br + "%s :: %s ->" % (x, rest) + bo + b1(env + [(x, "Int"), (rest, "LInt")]) + ")")
        if c == 3:
            l, x, rr = self.fresh(), self.fresh(), self.fresh()
            return (p(base) + "(case %s of" % sc("Tree") + br + "Leaf ->" + bo + b1(env)
                    + br + "Node %s %s %s ->" % (l, x, rr) + bo + b1(env + [(l, "Tree"), (x, "Int"), (rr, "Tree")]) + ")")
        if c == 4:
            x = self.fresh()
            return (p(base) + "(case %s of" % sc("MInt") + br + "Nothing ->" + bo + b1(env)
                    + br + "Just %s ->" % x + bo + b1(env + [(x, "Int")]) + ")")
        if c == 5:
            x, e = self.fresh(), self.fresh()
            return (p(base) + "(case %s of" % sc("Res") + br + "Ok %s ->" % x + bo + b1(env + [(x, "Int")])
                    + br + "Err %s ->" % e + bo + b1(env + [(e, "Str")]) + ")")
        if c == 6:
            a, b = self.fresh(), self.fresh()
            return p(base) + "(case %s of" % sc("Pair") + br + "( %s, %s ) ->" % (a, b) + bo + b1(env + [(a, "Int"), (b, "LInt")]) + ")"
        if c == 7:
            fs = [f for f in self.funs if f[2] == t]
            if fs:
                name, ps, _ = r.choice(fs)
                return "(%s %s)" % (name, " ".join(sc(pt) for pt in ps))
        if c == 8:
            ls = [l for l in self.loops if l[1] == t]
            if ls:
                return "(%s (modBy 4 %s) %s)" % (r.choice(ls)[0], sc("Int"), sc(t))
        if c == 9 and t != "Fn":
            # two list patterns deep
            x, y, rest = self.fresh(), self.fresh(), self.fresh()
            return (p(base) + "(case %s of" % sc("LInt") + br + "%s :: %s :: %s ->" % (x, y, rest) + bo + b1(env + [(x, "Int"), (y, "Int"), (rest, "LInt")])
                    + br + "_ ->" + bo + b1(env) + ")")
        return self.leaf(t, env)

    def program(self):
        r = self.r
        out = [PRELUDE]
        for i in range(r.randint(1, 3)):                       # loops: self tail calls with an accumulator
            t = r.choice([x for x in TYPES if x != "Fn"])
            name = "loop%d" % i
            n, acc = self.fresh("n"), self.fresh("acc")
            step = self.gen(t, [(n, "Int"), (acc, t)], 2, 12)
            out.append("\n\n%s : Int -> %s -> %s\n%s %s %s =\n    if %s <= 0 then\n        %s\n\n    else\n        %s (%s - 1)\n            %s\n"
                       % (name, ELM[t], ELM[t], name, n, acc, n, acc, name, n, step))
            self.loops.append((name, t))
        for i in range(r.randint(3, 6)):                       # functions: they call the earlier ones
            ps = [r.choice(TYPES) for _ in range(r.randint(1, 3))]
            t = r.choice(TYPES)
            name = "fun%d" % i
            names = [self.fresh("p") for _ in ps]
            body = self.gen(t, list(zip(names, ps)), 4, 4)
            out.append("\n\n%s : %s\n%s %s =\n    %s\n" % (name, " -> ".join(ELM[x] for x in ps + [t]), name, " ".join(names), body))
            self.funs.append((name, ps, t))
        outs = []
        for i in range(r.randint(4, 7)):
            t = r.choice([x for x in TYPES if x != "Fn"]) if r.random() < 0.9 else "Fn"
            e = self.gen(t, [], 4, 24)
            outs.append((i, t, e))
        lets = "".join("\n                    o%d =\n                        Debug.log \"o%d\" %s\n" % (i, i, e if t != "Fn" else "(%s 3)" % e) for i, t, e in outs)
        total = " + ".join("(" + (SIZE[t] if t != "Fn" else "%s") % ("o%d" % i) + ")" for i, t, e in outs)
        out.append('''

main : Program () () ()
main =
    Platform.worker
        { init =
            \\_ ->
                let%s                in
                if %s > 0 then
                    ( (), Cmd.none )

                else
                    ( (), Cmd.none )
        , update = \\_ m -> ( m, Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }
''' % (lets, total))
        return "".join(out)


def program_text(seed):
    return Gen(seed).program()


ELM_JSON = '''{"type": "application", "source-directories": ["src"], "elm-version": "0.19.3",
 "dependencies": {"direct": {"elm/core": "1.0.5"}, "indirect": {"elm/json": "1.1.3"}}, "test-dependencies": {"direct": {}, "indirect": {}}}
'''
CFLAGS = ["-std=c99", "-ffp-contract=off", "-w"]
SAN = ["-O1", "-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-g", "-DFIC_NO_POOL", "-DFIC_STATS"]


def sh(cmd, cwd=None, env=None, timeout=300):
    try:
        p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, timeout=timeout)
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"


def check(a, text, work, settings):
    """the failures of one program: [(setting, reason)]; ("generator", ...) when the program is not accepted without --rc"""
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(os.path.join(work, "src"))
    open(os.path.join(work, "elm.json"), "w").write(ELM_JSON)
    open(os.path.join(work, "src", "Main.fic"), "w").write(text)
    env = dict(os.environ, ELM_HOME=a.elm_home)
    for k in ("FICCUS_BORROW_PROJ", "FICCUS_BORROW_REUSE", "FICCUS_BORROW_S3", "FICCUS_NO_SPEC", "FICCUS_NO_REUSE"): env.pop(k, None)
    elm = os.path.abspath(a.elm)
    if a.elm_check:
        shutil.copy(os.path.join(work, "src", "Main.fic"), os.path.join(work, "src", "Main.elm"))
        rc, so, se = sh([a.safe, os.path.abspath(a.elm_check), "make", "src/Main.elm", "--output=/dev/null"], cwd=work, env=env)
        os.remove(os.path.join(work, "src", "Main.elm"))
        if rc != 0: return [("generator", "not valid Elm 0.19.3: " + (so + se)[-600:])]
    rc, so, se = sh([a.safe, elm, "make", "src/Main.fic", "--output=norc.c", "--no-rc"], cwd=work, env=env)
    if rc != 0: return [("generator", "the no-RC compile failed: " + (so + se)[-600:])]
    rc, so, se = sh(["gcc"] + CFLAGS + ["-O1", "norc.c", "-o", "norc", "-lm"], cwd=work)
    if rc != 0: return [("generator", "the no-RC C build failed: " + se[-400:])]
    rc, oracle, se = sh([a.safe, "./norc"], cwd=work)
    if rc != 0: return [("generator", "the no-RC program failed (exit %d): %s" % (rc, se[-300:]))]
    bad = []
    for st in settings:
        e = dict(env, **SETTINGS[st])
        rc, so, se = sh([a.safe, elm, "make", "src/Main.fic", "--output=rc.c", "--rc"], cwd=work, env=e)
        if rc != 0: bad.append((st, ("RcCheck rejects the program: " if "rc check:" in so + se else "the --rc compile failed: ") + (so + se)[-600:])); continue
        rc, so, se = sh(["gcc"] + CFLAGS + SAN + ["rc.c", "-o", "rc", "-lm"], cwd=work)
        if rc != 0: bad.append((st, "the --rc C build failed: " + se[-400:])); continue
        rc, got, se = sh([a.safe, "./rc"], cwd=work, env=dict(os.environ, ASAN_OPTIONS="detect_leaks=1"))
        if rc != 0: bad.append((st, "exit %d: %s" % (rc, se[-700:])))
        elif got != oracle: bad.append((st, "output differs from the no-RC build"))
        elif " live 0 " not in se: bad.append((st, "not 0 live objects: " + se[-200:]))
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm"); ap.add_argument("--elm-home"); ap.add_argument("--safe")
    ap.add_argument("--count", type=int, default=500); ap.add_argument("--first", type=int, default=1)
    ap.add_argument("--settings", default="default,proj,reuse"); ap.add_argument("--out", default=None)
    ap.add_argument("--keep", default=os.path.join(HERE, "rcfuzz")); ap.add_argument("--elm-check", default=None)
    ap.add_argument("--print", type=int, default=None, dest="show"); ap.add_argument("--replay", action="store_true")
    a = ap.parse_args()
    if a.show is not None:
        sys.stdout.write(program_text(a.show)); return 0
    settings = [s for s in a.settings.split(",") if s]
    work = a.out or tempfile.mkdtemp(prefix="rcfuzz")
    a.safe = os.path.abspath(a.safe)
    if a.replay:
        files = sorted(f for f in os.listdir(a.keep) if f.endswith(".fic")) if os.path.isdir(a.keep) else []
        jobs = [(f, open(os.path.join(a.keep, f)).read()) for f in files]
    else:
        jobs = [("seed%d" % n, program_text(n)) for n in range(a.first, a.first + a.count)]
    fails = {s: 0 for s in settings}; gen_bad = 0
    for i, (name, text) in enumerate(jobs, 1):
        bad = check(a, text, os.path.join(work, "p"), settings)
        for st, why in bad:
            if st == "generator": gen_bad += 1
            else: fails[st] += 1
            print("FAIL %s %s: %s" % (name, st, why.replace("\n", " | ")[:900]), flush=True)
            if not a.replay:
                os.makedirs(a.keep, exist_ok=True)
                with open(os.path.join(a.keep, "%s_%s.fic" % (name, st)), "w") as f:
                    f.write(text + "\n-- rcfuzz: failed with setting %s: %s\n" % (st, why.replace("\n", " | ")[:300]))
        if i % 25 == 0: print("... %d of %d programs, failures %s, generator problems %d" % (i, len(jobs), fails, gen_bad), flush=True)
    print("rcfuzz: %d programs (%s), settings %s: failures %s, generator problems %d"
          % (len(jobs), "replay" if a.replay else "seeds %d..%d" % (a.first, a.first + a.count - 1), ",".join(settings), fails, gen_bad))
    if not a.out: shutil.rmtree(work, ignore_errors=True)
    return 1 if gen_bad or any(fails.values()) else 0


if __name__ == "__main__":
    sys.exit(main())
