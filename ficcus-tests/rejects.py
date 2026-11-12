#!/usr/bin/env python3
"""rejects.py -- the compile time checks of the C back end (decisions L2 and L9): an Int literal beyond 2^63-1 (decimal, hex, in a
pattern) and a surrogate in a string literal are errors with these titles; the smallest Int written as -9223372036854775807 - 1 and
the largest literal are accepted; the JavaScript build still accepts all of them (Elm's behaviour, the corpus comparisons stay equal).
usage: rejects.py --elm BIN --safe tools/safe --elm-home DIR"""
import argparse, os, shutil, subprocess, sys, tempfile

HEAD = '''module Main exposing (main)


main : Program () () ()
main =
    Platform.worker
        { init = \\_ -> ( (), Cmd.none )
        , update = \\_ m -> ( m, Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }

'''
CASES = [   # (name, body, expected: None = accepted, else a text of the error)
    ("big-decimal", "x : Int\nx =\n    9223372036854775808\n", "This integer is too large for an `Int`"),
    ("big-1e26", "x : Int\nx =\n    123300000000000000000000000\n", "This integer is too large for an `Int`"),
    ("big-hex", "x : Int\nx =\n    0xFFFFFFFFFFFFFFFF\n", "This integer is too large for an `Int`"),
    ("big-pattern", "f : Int -> Int\nf n =\n    case n of\n        9223372036854775808 ->\n            1\n\n        _ ->\n            2\n", "This integer is too large for an `Int`"),
    ("max-ok", "x : Int\nx =\n    9223372036854775807\n", None),
    ("min-ok", "x : Int\nx =\n    -9223372036854775807 - 1\n", None),
    ("surrogate-low", 'x : String\nx =\n    "a\\u{DD56}"\n', "This is a surrogate, not a character"),
    ("surrogate-high", 'x : String\nx =\n    "\\u{D800}"\n', "This is a surrogate, not a character"),
    # syntax track E5 (underscores in numbers) and E2 (list type): the errors
    ("us-end", "x : Int\nx =\n    1_\n", "needs a digit on both sides"),
    ("us-before-dot", "x : Float\nx =\n    1_.5\n", "needs a digit on both sides"),
    ("us-after-dot", "x : Float\nx =\n    1._5\n", "Numbers cannot end with a dot"),
    ("us-hex-prefix", "x : Int\nx =\n    0x_FF\n", "WEIRD HEXIDECIMAL"),
    ("us-leading-zero", "x : Int\nx =\n    0_1\n", "leading zeros"),
    ("us-name", "x : Int\nx =\n    1_x\n", "needs a digit on both sides"),
    ("list-type-open", "x : [Int\nx =\n    []\n", "closing square bracket"),
    ("near-ok", 'x : String\nx =\n    "\\u{D7FF}\\u{E000}"\n', None),
]

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--elm", required=True); ap.add_argument("--safe", required=True); ap.add_argument("--elm-home", required=True)
    a = ap.parse_args(); bad = 0
    elm_json = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "order", "elm.json")).read()
    for name, body, want in CASES:
        d = tempfile.mkdtemp(); os.makedirs(os.path.join(d, "src")); open(os.path.join(d, "elm.json"), "w").write(elm_json)
        src = os.path.join(d, "src", "Main.fic"); open(src, "w").write(HEAD + body)
        env = dict(os.environ, ELM_HOME=a.elm_home)
        c = subprocess.run([a.safe, a.elm, "make", "src/Main.fic", "--output=x.c"], cwd=d, env=env, capture_output=True, text=True)
        text = c.stdout + c.stderr
        ok = (c.returncode == 0) if want is None else (c.returncode != 0 and want in text)
        # the JavaScript build accepts the same program (Elm 0.19.3's own behaviour)
        shutil.copy(src, os.path.join(d, "src", "Main.elm")); os.remove(src); shutil.rmtree(os.path.join(d, "elm-stuff"), ignore_errors=True)
        j = subprocess.run([a.safe, a.elm, "make", "src/Main.elm", "--output=x.js"], cwd=d, env=env, capture_output=True, text=True)
        if name.startswith(("big", "surrogate")) and j.returncode != 0: ok = False; text += "\n(the JS build rejected it)"
        print(("ok   " if ok else "FAIL ") + "rejects " + name); bad += 0 if ok else 1
        if not ok: print(text[-300:])
        shutil.rmtree(d, ignore_errors=True)
    # L42: elm/json is only an indirect dependency (reached through miniBill/elm-codec, the project of the example indirectjson): the
    # overlay may import it, the program may not (Elm's rule and Elm's message)
    d = tempfile.mkdtemp(); os.makedirs(os.path.join(d, "src"))
    shutil.copy(os.path.join(os.path.dirname(os.path.abspath(__file__)), "indirectjson", "elm.json"), d)
    open(os.path.join(d, "src", "Main.fic"), "w").write(HEAD.replace("\n\n\nmain :", "\n\nimport Codec\nimport Json.Decode\n\n\nmain :", 1))
    c = subprocess.run([a.safe, a.elm, "make", "src/Main.fic", "--output=x.c"], cwd=d, env=dict(os.environ, ELM_HOME=a.elm_home), capture_output=True, text=True)
    ok = c.returncode != 0 and "Running elm install elm/json should make it available" in c.stdout + c.stderr
    print(("ok   " if ok else "FAIL ") + "rejects import-of-indirect-package"); bad += 0 if ok else 1
    if not ok: print((c.stdout + c.stderr)[-300:])
    shutil.rmtree(d, ignore_errors=True)
    return 1 if bad else 0

if __name__ == "__main__": sys.exit(main())
