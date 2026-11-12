#!/usr/bin/env python3
"""Differential test of the Regex kernel (decision L24) against Elm 0.19.3 under node, and against node's RegExp.

  python3 ficcus-tests/regex/run_diff.py --elm bin/elmficrN --elm-ref bin/elm0193 --elm-home H --work DIR [--seed 1] [--random 200] [--san] [--keep]

One Elm program holds the cases (flags, pattern, subject: hand-written edge cases and random ones from a fixed seed, gen_cases.py). For each
case it prints one line with `fromStringWith` (Nothing or not), `contains`, `find`, `findAtMost 2`, `replace`, `replaceAtMost 2`, `split` and
`splitAtMost 2`. It is built three ways:
  F  the Ficcus compiler (--rc, ASan+UBSan with --san) and run,
  A  Elm 0.19.3 (the reference compiler), run under node,
  B  a JavaScript model of the decided behaviour (ref_api.js): node's RegExp with the iteration rules of L24 (matchAll for find and replace,
     the specification of String.prototype.split for split, an empty capture is Just "").
F must equal B on every case. F must equal A on every case where Elm's own behaviour is the decided one: Elm differs (decisions L24, L30, and the
library cases R-find-empty-matches, R-capture-empty, R-split-*) when a match is empty or a capture is the empty string; those cases are not run
under Elm (its split loops forever on an empty match) and are reported as "model only". Patterns that node accepts and Ficcus rejects by design
(inline flags) are listed in UNSUPPORTED: F must say Nothing for them. Exit status 1 on any difference."""
import argparse, json, os, re, subprocess, sys, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_cases  # noqa: E402

UNSUPPORTED = {"(?i)a"}
IDENTITY_P = ["\\p{L}", "\\P{L}", "\\p", "\\p{Letter}+", "[\\p{L}]"]      # \p, \P are identity escapes as in node without the u flag
EXTRA = [(0, p, "ab a") for p in sorted(UNSUPPORTED)] + [(0, p, "ap{L} P{L} p{Letter}p L}") for p in IDENTITY_P]


def elm_str(s):
    out = []
    for ch in s:
        o = ord(ch)
        if ch == '"' or ch == "\\":
            out.append("\\" + ch)
        elif 32 <= o < 127:
            out.append(ch)
        else:
            out.append("\\u{%04X}" % o)
    return '"' + "".join(out) + '"'


MAIN = r'''module Main exposing (main)

import Bitwise
import Regex


cases : List ( Int, String, String )
cases =
    [ %s
    ]


esc : String -> String
esc s =
    String.concat (List.map escChar (String.toList s))


escChar : Char -> String
escChar c =
    let
        n =
            Char.toCode c
    in
    if n >= 32 && n < 127 && c /= '\\' && c /= '"' && c /= '~' then
        String.fromChar c

    else
        "~u{" ++ String.fromInt n ++ "}"


showSub : Maybe String -> String
showSub m =
    case m of
        Nothing ->
            "-"

        Just s ->
            "+" ++ esc s


showM : Regex.Match -> String
showM m =
    "(" ++ esc m.match ++ "," ++ String.fromInt m.index ++ "," ++ String.fromInt m.number ++ "," ++ String.join ";" (List.map showSub m.submatches) ++ ")"


showList : List String -> String
showList l =
    "[" ++ String.join "|" l ++ "]"


runCase : ( Int, String, String ) -> String
runCase ( f, p, s ) =
    case Regex.fromStringWith { caseInsensitive = Bitwise.and f 1 == 1, multiline = Bitwise.and f 2 == 2 } p of
        Nothing ->
            "N"

        Just re ->
            let
                rep m =
                    "<" ++ showM m ++ ">"
            in
            String.join " "
                [ if Regex.contains re s then "T" else "F"
                , showList (List.map showM (Regex.find re s))
                , showList (List.map showM (Regex.findAtMost 2 re s))
                , esc (Regex.replace re rep s)
                , esc (Regex.replaceAtMost 2 re rep s)
                , showList (List.map esc (Regex.split re s))
                , showList (List.map esc (Regex.splitAtMost 2 re s))
                ]


run : () -> Int
run _ =
    List.sum (List.indexedMap (\i c -> String.length (Debug.log ("c" ++ String.fromInt i) (runCase c))) cases)


main : Program () Int ()
main =
    Platform.worker
        { init = \_ -> ( run (), Cmd.none )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
'''

ELM_JSON = '''{"type": "application", "source-directories": ["src"], "elm-version": "0.19.3",
 "dependencies": {"direct": {"elm/core": "1.0.5", "elm/json": "1.1.3", "elm/regex": "1.0.0"}, "indirect": {}}, "test-dependencies": {"direct": {}, "indirect": {}}}
'''


def program(cases):
    return MAIN % "\n    , ".join("( %d, %s, %s )" % (f, elm_str(p), elm_str(s)) for f, p, s in cases)


def sh(cmd, cwd=None, env=None, timeout=900, stdin=None):
    try:
        p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, timeout=timeout, input=stdin)
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"


def logs(text):
    """the Debug.log lines `cN: "value"` as {N: value}; the value is a quoted Elm string of printable ASCII"""
    out = {}
    for line in text.splitlines():
        if line.startswith("c") and ": " in line:
            k, v = line[1:].split(": ", 1)
            if k.isdigit():
                out[int(k)] = v[1:-1] if v[:1] == '"' and v[-1:] == '"' else v
    return out


NAMED = re.compile(r"\(\?<[A-Za-z_$]")
LINE = re.compile(r"^([TF]) (\[.*?\]) (\[.*?\]) .* (\[.*?\]) (\[.*\])$")


def no_replace(line):
    """Elm's `replace` hands the callback the object of the named groups as one more argument (index and submatches of the Match are then
    garbage): for patterns with named groups the two `replace` columns are compared with the model only"""
    m = LINE.match(line or "")
    return " ".join(m.groups()) if m else line


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--elm-ref", required=True); ap.add_argument("--elm-home", required=True)
    ap.add_argument("--work", required=True); ap.add_argument("--safe", default=None)
    ap.add_argument("--seed", type=int, default=1); ap.add_argument("--random", type=int, default=200)
    ap.add_argument("--san", action="store_true"); ap.add_argument("--keep", action="store_true")
    ap.add_argument("--min-pairs", type=int, default=200)
    a = ap.parse_args()
    safe = [a.safe] if a.safe else []
    work = os.path.abspath(a.work)
    shutil.rmtree(work, ignore_errors=True)
    # the cases: hand written, the ones that are rejected by design, random (patterns of the supported subset with a few errors)
    import random
    r = random.Random(a.seed)
    cases = list(gen_cases.HAND) + EXTRA
    for _ in range(a.random):
        p = gen_cases.rnd_pat(r)
        if r.random() < 0.05:
            i = r.randint(0, len(p)); p = p[:i] + r.choice("()[]{}*+?|\\^$.-,") + p[i:]
        s = "".join(r.choice(gen_cases.SUBJ) for _ in range(r.randint(0, 12)))
        cases.append((r.choice([0, 0, 0, 1, 2, 3]), p, s))
    cases = [c for c in cases if "\x00" not in c[2] and "\x00" not in c[1]]
    # B: the model
    inp = json.dumps(cases)
    rc, so, se = sh(["node", os.path.join(HERE, "ref_api.js")], stdin=inp.encode("utf-8"))
    if rc != 0:
        print("ref_api.js failed:", se[-500:]); return 1
    model = json.loads(so)
    expected = []                                # B per case, with the cases rejected by design forced to N
    for (f, p, s), m in zip(cases, model):
        expected.append("N" if p in UNSUPPORTED else m["line"])
    quirk = [m["quirk"] and p not in UNSUPPORTED for (f, p, s), m in zip(cases, model)]
    # F: Ficcus
    for name in ("f", "a"):
        os.makedirs(os.path.join(work, name, "src"))
        open(os.path.join(work, name, "elm.json"), "w").write(ELM_JSON)
    open(os.path.join(work, "f", "src", "Main.fic"), "w", encoding="utf-8").write(program(cases))
    env = dict(os.environ, ELM_HOME=a.elm_home)
    fdir = os.path.join(work, "f")
    rc, so, se = sh(safe + [os.path.abspath(a.elm), "make", "src/Main.fic", "--output=f.c", "--rc"], cwd=fdir, env=env)
    if rc != 0:
        print("the Ficcus compile failed:", (so + se)[-1500:]); return 1
    flags = ["-std=c99", "-ffp-contract=off", "-w", "-O1", "-DFIC_STATS"] + (["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-g", "-DFIC_NO_POOL"] if a.san else [])
    rc, so, se = sh(["gcc"] + flags + ["f.c", "-o", "f", "-lm"], cwd=fdir)
    if rc != 0:
        print("the C build failed:", se[-1500:]); return 1
    rc, so, se = sh(safe + ["./f"], cwd=fdir, env=dict(os.environ, SAFE_TIMEOUT="600", SAFE_MEM="6G"), timeout=900)
    if rc != 0:
        print("the Ficcus program failed: exit", rc, se[-800:]); return 1
    if " live 0 " not in se:
        print("not 0 live objects:", se[-300:]); return 1
    got = logs(so)
    # A: Elm 0.19.3 on the cases where Elm's behaviour is the decided one
    elm_idx = [i for i in range(len(cases)) if not quirk[i] and cases[i][1] not in UNSUPPORTED]
    sub = [cases[i] for i in elm_idx]
    adir = os.path.join(work, "a")
    open(os.path.join(adir, "src", "Main.elm"), "w", encoding="utf-8").write(program(sub))
    rc, so, se = sh(safe + [os.path.abspath(a.elm_ref), "make", "src/Main.elm", "--output=a.js"], cwd=adir, env=env)
    if rc != 0:
        print("the Elm compile failed:", (so + se)[-1500:]); return 1
    open(os.path.join(adir, "run.js"), "w").write("var E = require('./a.js'); E.Elm.Main.init();\n")
    rc, so, se = sh(safe + ["node", "run.js"], cwd=adir, env=dict(os.environ, SAFE_TIMEOUT="300"), timeout=600)
    if rc != 0:
        print("the Elm program failed: exit", rc, (se + so)[-800:]); return 1
    ref = logs(so + se)
    bad = 0
    f_vs_b = f_vs_a = 0
    for i, c in enumerate(cases):
        if got.get(i) != expected[i]:
            bad += 1
            print("F != B  case %d %r\n   F: %s\n   B: %s" % (i, c, got.get(i), expected[i]))
        else:
            f_vs_b += 1
    for j, i in enumerate(elm_idx):
        a_line, f_line = ref.get(j), got.get(i)
        if NAMED.search(cases[i][1]):
            a_line, f_line = no_replace(a_line), no_replace(f_line)
        if a_line != f_line:
            bad += 1
            print("F != A  case %d %r\n   F: %s\n   A: %s" % (i, cases[i], got.get(i), ref.get(j)))
        else:
            f_vs_a += 1
    nothing = sum(1 for e in expected if e == "N")
    print("cases %d (%d invalid patterns, %d rejected by design); F = model on %d; F = Elm on %d of %d (%d cases model only: Elm differs by decision)"
          % (len(cases), nothing, sum(1 for c in cases if c[1] in UNSUPPORTED), f_vs_b, f_vs_a, len(elm_idx), len(cases) - len(elm_idx) - sum(1 for c in cases if c[1] in UNSUPPORTED)))
    if len(elm_idx) < a.min_pairs:
        print("only %d pairs compared with Elm (need %d)" % (len(elm_idx), a.min_pairs)); bad += 1
    if not a.keep:
        shutil.rmtree(work, ignore_errors=True)
    print("OK" if bad == 0 else "FAIL (%d)" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
