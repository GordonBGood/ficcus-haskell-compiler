#!/usr/bin/env python3
"""g70gen.py -- writes the G70 member visibility cases (cases/g70-*) and prints their expected.tsv lines.

Rule (decision of rev 176, amending rev 128 and A2): the members of a type are visible wherever the type NAME is
exported; `(..)` controls only the constructors.  Every case exists twice: `g70-open-*` (Finance exports `Money(..)`)
and `g70-opaque-*` (Finance exports `Money`).  Run from this directory: python3 g70gen.py [--write]"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))

FINANCE = """module Finance exposing ({export}, fromInt)


type Money = Money Int
    where
        zero : Money
        zero = Money 0

        add : Money -> Money -> Money
        add (Money a) (Money b) = Money (a + b)

        compare : Money -> Money -> Order
        compare (Money a) (Money b) = Basics.compare a b

        toInt : Money -> Int
        toInt (Money a) = a


fromInt : Int -> Money
fromInt =
    Money


-- an ordinary function, not a member and not exported: it stays hidden
raw : Money -> Int
raw (Money a) =
    a
"""

ALGEBRA = """module Algebra exposing (sum)


sum : List a -> a
    where
        a has zero : a
        a has add : a -> a -> a
sum xs =
    List.foldl add zero xs
"""

# a third module: Elm has no re-export of an imported type, so Bank gives it a new name (an alias) and functions that make it
BANK = """module Bank exposing (Cash, deposit, combine)

import Finance exposing (Money)


type alias Cash =
    Money


deposit : Int -> Cash
deposit =
    Finance.fromInt


combine : Cash -> Cash -> Cash
combine a b =
    Money.add a b
"""

MAIN = """module Main exposing (main)

{imports}


main : Program () () ()
main =
    Platform.worker
        {{ init =
            \\_ ->
                let
                    _ =
                        Debug.log "r" ({expr})
                in
                ( (), Cmd.none )
        , update = \\_ m -> ( m, Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }}
"""

# member calls through each import form: (toInt (add a b), compare a b)
def calls(q, mk):
    return "( {q}.toInt ({q}.add ({mk} 1) ({mk} 2)), {q}.compare ({mk} 1) ({mk} 2) )".format(q=q, mk=mk)

OUT_CALLS = "r: (3,LT)\n"

# id, desc, imports, expr, needs (extra modules), expected under the new rule for (open, opaque), expected output
# an expectation is ("RUN", kinds) or ("REJECT", titles, text)
CASES = [
    ("exp-type", "import Finance exposing (Money): Money.add, Money.compare, Money.toInt",
     "import Finance exposing (Money)", calls("Money", "Finance.fromInt"), [], ("RUN", "js+c"), ("RUN", "js+c")),
    ("exp-open", "import Finance exposing (Money(..)): Money.add, Money.compare, Money.toInt",
     "import Finance exposing (Money(..))", calls("Money", "Finance.fromInt"), [], ("RUN", "js+c"), ("RUN", "js+c")),
    ("exp-all", "import Finance exposing (..): Money.add, Money.compare, Money.toInt",
     "import Finance exposing (..)", calls("Money", "fromInt"), [], ("RUN", "js+c"), ("RUN", "js+c")),
    ("qual", "import Finance (qualified only): Finance.Money.add",
     "import Finance", calls("Finance.Money", "Finance.fromInt"), [], ("RUN", "js+c"), ("RUN", "js+c")),
    ("alias", "import Finance as F: F.Money.add",
     "import Finance as F", calls("F.Money", "F.fromInt"), [], ("RUN", "js+c"), ("RUN", "js+c")),
    ("alias-exp-type", "import Finance as F exposing (Money): Money.add",
     "import Finance as F exposing (Money)", calls("Money", "F.fromInt"), [], ("RUN", "js+c"), ("RUN", "js+c")),
    ("constraint", "import Finance exposing (Money): Algebra.sum over Money (a has zero, a has add)",
     "import Algebra\nimport Finance exposing (Money)",
     "Money.toInt (Algebra.sum [ Finance.fromInt 1, Finance.fromInt 2 ])", ["Algebra"], ("RUN", "c"), ("RUN", "c")),
    ("flow", "Money flows in through Bank (an alias and functions); Main imports neither Finance nor names Money; Algebra.sum finds the members through Finance",
     "import Algebra\nimport Bank",
     "Bank.combine (Algebra.sum [ Bank.deposit 1, Bank.deposit 2 ]) (Bank.deposit 10)", ["Algebra", "Bank"], ("RUN", "c"), ("RUN", "c")),
    ("reexport-qual", "Money comes from Bank, the members are called through import Finance (qualified only)",
     "import Bank\nimport Finance",
     "( Finance.Money.toInt (Finance.Money.add (Bank.deposit 1) (Bank.deposit 2)), Finance.Money.compare (Bank.deposit 1) (Bank.deposit 2) )",
     ["Bank"], ("RUN", "js+c"), ("RUN", "js+c")),
    ("reexport-alias-name", "Bank's alias Cash does not carry the members of Money: Cash.add is unknown (members follow the type name, an alias is another name)",
     "import Bank exposing (Cash)", "Cash.add (Bank.deposit 1) (Bank.deposit 2)", ["Bank"],
     ("REJECT", "NAMING ERROR", "Cash.add"), ("REJECT", "NAMING ERROR", "Cash.add")),
    ("reexport-unimported", "Finance.Money.add without importing Finance (only Bank): unknown, as any qualified name of a module not imported",
     "import Bank", "Finance.Money.add (Bank.deposit 1) (Bank.deposit 2)", ["Bank"],
     ("REJECT", "NAMING ERROR", "Finance.Money.add"), ("REJECT", "NAMING ERROR", "Finance.Money.add")),
    # constructors: (..) alone decides
    ("ctor-exp-open", "import Finance exposing (Money(..)): the constructor Money",
     "import Finance exposing (Money(..))", "Money.toInt (Money 5)", [], ("RUN", "js+c"), ("REJECT", "NAMING ERROR", "Money")),
    ("ctor-exp-all", "import Finance exposing (..): the constructor Money",
     "import Finance exposing (..)", "Money.toInt (Money 5)", [], ("RUN", "js+c"), ("REJECT", "NAMING ERROR", "Money")),
    ("ctor-qual", "import Finance: the constructor Finance.Money",
     "import Finance", "Finance.Money.toInt (Finance.Money 5)", [], ("RUN", "js+c"), ("REJECT", "NAMING ERROR", "Finance.Money")),
    ("ctor-exp-type", "import Finance exposing (Money): the constructor is not exposed unqualified",
     "import Finance exposing (Money)", "Money.toInt (Money 5)", [], ("REJECT", "NAMING ERROR", "Money"), ("REJECT", "NAMING ERROR", "Money")),
    ("ctor-pattern", "import Finance: a pattern on the constructor Finance.Money",
     "import Finance\n\n\nunwrap : Finance.Money -> Int\nunwrap m =\n    case m of\n        Finance.Money n ->\n            n",
     "unwrap (Finance.fromInt 5)", [], ("RUN", "js+c"), ("REJECT", "NAMING ERROR", "Finance.Money")),
    # an ordinary unexported function stays hidden (the way to keep a function that exposes the representation private)
    ("unexported-fn", "Finance.raw is an ordinary function, not exported: unknown",
     "import Finance", "Finance.raw (Finance.fromInt 1)", [], ("REJECT", "NAMING ERROR", "Finance.raw"), ("REJECT", "NAMING ERROR", "Finance.raw")),
]

OUTPUTS = {
    "constraint": "r: 3\n", "flow": "r: Money 13\n", "reexport-alias-name": None, "ctor-exp-open": "r: 5\n",
    "ctor-exp-all": "r: 5\n", "ctor-qual": "r: 5\n", "ctor-pattern": "r: 5\n",
}

# a type whose name is not exported: its members stay hidden even when a value of it flows out
PRIVATE = [
    ("g70-private-type-call", "Finance exports fromInt : Int -> Money but not the type Money: Finance.Money.add is unknown",
     "import Finance", "Finance.Money.toInt (Finance.fromInt 1)", ("REJECT", "NAMING ERROR", "Finance.Money.toInt")),
    ("g70-private-type-flow", "Finance exports fromInt : Int -> Money but not the type Money: a constraint at Money is not satisfied (the members are hidden with the name)",
     "import Algebra\nimport Finance", "Algebra.sum [ Finance.fromInt 1, Finance.fromInt 2 ]", None),
]


def write(cid, desc, files, out):
    d = os.path.join(HERE, "cases", cid)
    os.makedirs(d, exist_ok=True)
    for name, text in files.items():
        open(os.path.join(d, name), "w").write(text)
    json.dump({"desc": desc}, open(os.path.join(d, "case.json"), "w"), indent=1)
    if out is not None:
        open(os.path.join(d, "expected.out"), "w").write(out)


def line(cid, want):
    if want[0] == "RUN":
        return "%s\tRUN\t%s\t" % (cid, want[1])
    return "%s\tREJECT\t%s\t%s" % (cid, want[1], want[2])


def main():
    do = "--write" in sys.argv
    lines = []
    for (name, desc, imports, expr, needs, w_open, w_opaque) in CASES:
        for variant, export, want in (("open", "Money(..)", w_open), ("opaque", "Money", w_opaque)):
            cid = "g70-%s-%s" % (variant, name)
            files = {"Finance.elm": FINANCE.format(export=export), "Main.elm": MAIN.format(imports=imports, expr=expr)}
            if "Algebra" in needs: files["Algebra.elm"] = ALGEBRA
            if "Bank" in needs: files["Bank.elm"] = BANK
            out = OUTPUTS.get(name, OUT_CALLS) if want[0] == "RUN" else None
            if do: write(cid, "G70 (%s: Finance exports %s): %s" % (variant, export, desc), files, out)
            lines.append(line(cid, want))
    for (cid, desc, imports, expr, want) in PRIVATE:
        fin = FINANCE.replace("exposing ({export}, fromInt)", "exposing (fromInt)")
        files = {"Finance.elm": fin, "Main.elm": MAIN.format(imports=imports, expr=expr)}
        if "Algebra" in imports: files["Algebra.elm"] = ALGEBRA
        if want is None: want = ("REJECT", "NO ATTACHED FUNCTION", "has no attached functions that I can see here")
        if do: write(cid, "G70: " + desc, files, None)
        lines.append(line(cid, want))
    # pure Elm (no members): an opaque type and its import forms, the same as Elm 0.19.3 (also compared as JS text by hand)
    elm = {"Purse.elm": "module Purse exposing (Purse, make, value)\n\n\ntype Purse = Purse Int\n\n\nmake : Int -> Purse\nmake =\n    Purse\n\n\nvalue : Purse -> Int\nvalue (Purse n) =\n    n\n",
           "Main.elm": MAIN.format(imports="import Purse exposing (Purse)\nimport Purse as P", expr="( Purse.value (Purse.make 3), P.value (P.make 4) )")}
    if do: write("g70-elm-opaque", "G70: pure Elm, an opaque type imported with exposing (Purse) and through an alias: unchanged", elm, "r: (3,4)\n")
    lines.append("g70-elm-opaque\tRUN\tjs+c\t")
    print("\n".join(lines))


main()
