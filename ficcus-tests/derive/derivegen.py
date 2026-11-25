#!/usr/bin/env python3
"""derivegen.py -- the A4a derive matrix (docs/A4-DERIVE-DESIGN.md, slice A4a: syntax and checks; no member bodies yet).

  python3 ficcus-tests/derive/derivegen.py --write      # (re)writes cases/ and expected.tsv
  python3 ficcus-tests/derive/derive.py --elm bin/elmficA4a

Outcomes are those of ficcus-tests/attach/attach.py (REJECT: the JavaScript build fails with these titles; REJECTC: the
build to C fails with this report; RUN c: the C program prints expected.out).  A program with a `derive` line has no
JavaScript build (DERIVED MEMBERS), so every accepted case is `c_only` and RUN c.  In A4a a derived member has its
signature (with `a has m` for the parameters) but no body: a program that uses one is refused by the C generator
(REJECTC, "is not generated yet").  Standard library only."""
import json, os, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases")
JSON = "elm/json@1.1.3"


def worker(decls, expr, header="module Main exposing (main)", imports=""):
    return """%s
%s


%s


main : Program () () ()
main =
    Platform.worker
        { init =
            \\_ ->
                let
                    _ =
                        Debug.log "r" (%s)
                in
                ( (), Cmd.none )
        , update = \\_ m -> ( m, Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }
""" % (header, imports, decls.strip("\n"), expr)


COLOR = """
type Color
    = Red
    | Green
    | Blue
    where
        derive compare, hash, toString, encode, decoder, minValue, maxValue, succ, pred, enumerate

        name : Color -> String
        name c =
            case c of
                Red -> "red"
                Green -> "green"
                Blue -> "blue"
"""

TREE = """
type Tree a
    = Leaf
    | Node (Tree a) a (Tree a)
    where
        derive compare, hash, toString, encode, decoder, map

        size : Tree a -> Int
        size t =
            case t of
                Leaf -> 0
                Node l _ r -> size l + 1 + size r
"""

EMAIL = """
type Email = Email String where derive compare, hash, toString, encode, decoder
"""

USER = """
type User
    = User { name : String, email : Email, bio : Maybe String }
    where
        derive compare, hash, toString, encode, decoder
"""

# (id, outcome, titles/runs, text, files, extra case.json, expected.out)
CASE_LIST = []


def case(cid, outcome, col3, col4, files, meta=None, out=None):
    CASE_LIST.append((cid, outcome, col3, col4, files, meta or {}, out))


C_ONLY = {"c_only": True}
C_JSON = {"c_only": True, "deps": [JSON]}

# ---- accepted: the derive line in its forms, the members unused (RUN c) ----

case("ok-enum-all", "RUN", "c", "", {"Main.elm": worker(COLOR, "List.map Color.name [ Red, Green, Blue ]")}, C_JSON,
     'r: ["red","green","blue"]\n')
case("ok-oneline", "RUN", "c", "", {"Main.elm": worker("type Email = Email String where derive compare, hash",
     '(\\(Email s) -> s) (Email "a@b")')}, C_ONLY, 'r: "a@b"\n')
case("ok-multiline", "RUN", "c", "", {"Main.elm": worker("""
type Money
    = Money Int
    where
        zero : Money
        zero = Money 0

        derive compare,
            hash ,toString

        add : Money -> Money -> Money
        add (Money a) (Money b) = Money (a + b)

        toInt : Money -> Int
        toInt (Money a) = a
""", "Money.toInt (Money.add Money.zero (Money 42))")}, C_ONLY, "r: 42\n")
case("ok-first-line", "RUN", "c", "", {"Main.elm": worker("""
type Money
    = Money Int
    where
        derive hash
        toInt : Money -> Int
        toInt (Money a) = a
""", "Money.toInt (Money 7)")}, C_ONLY, "r: 7\n")
case("ok-record-wrapper", "RUN", "c", "", {"Main.elm": worker(EMAIL + USER,
     '(\\(User u) -> u.name) (User { name = "Bo", email = Email "b@o", bio = Nothing })')}, C_JSON, 'r: "Bo"\n')
case("ok-tree", "RUN", "c", "", {"Main.elm": worker(TREE, "Tree.size (Node (Node Leaf 1 Leaf) 2 Leaf)")}, C_JSON, "r: 2\n")
case("ok-builtins", "RUN", "c", "", {"Main.elm": worker("""
type Mixed
    = Mixed Int Float String Char Bool () ( Int, String ) (List Int) (Maybe Order) (Result String Int)
    | Other (Array.Array Int) (Dict.Dict String Int) (Set.Set Int) { x : Int, y : ( Bool, Char, Float ) }
    where
        derive compare, hash, toString, fromString, encode, decoder
""", "1", imports="import Array\nimport Dict\nimport Set\n")}, C_JSON, "r: 1\n")
case("ok-json-value", "RUN", "c", "", {"Main.elm": worker("""
type Payload = Payload Json.Encode.Value where derive encode, decoder
""", "1", imports="import Json.Encode\n")}, C_JSON, "r: 1\n")
case("ok-own-json-imports", "RUN", "c", "", {"Main.elm": worker("""
type Payload = Payload Int where derive encode, decoder

enc : Int -> E.Value
enc = E.int

dec : D.Decoder Int
dec = D.int
""", 'E.encode 0 (enc 3)', imports="import Json.Encode as E\nimport Json.Decode as D\n")}, C_JSON, 'r: "3"\n')
# A4a reading of DERIVE SHADOWED: any top level function of the member's name in the module, exposed or not (stricter than
# section 4 of the note; can be relaxed later without breaking a program)
case("shadowed-helper", "REJECT", "DERIVE SHADOWED", "hash", {"Main.elm": worker("""
type Color = Red | Blue where derive hash

hash : Int -> Int
hash n = n * 31
""", "hash 2")})
case("ok-siblings", "RUN", "c", "", {"Main.elm": worker("""
type Color
    = Red
    | Blue
    where
        derive compare

        larger : Color -> Color -> Color
        larger a b =
            if compare a b == GT then a else b
""", "1")}, C_ONLY, "r: 1\n")
case("ok-written-inner", "RUN", "c", "", {"Main.elm": worker("""
type Money
    = Money Int
    where
        compare : Money -> Money -> Order
        compare (Money a) (Money b) = Basics.compare a b

type Wallet = Wallet (List Money) where derive compare
""", "1")}, C_ONLY, "r: 1\n")
case("ok-order-type-shadow", "RUN", "c", "", {"Main.elm": worker("""
type Order = Order Int where derive compare, fromString

type Maybe = Maybe where derive succ, enumerate
""", "1")}, C_ONLY, "r: 1\n")

# ---- the parameter constraint (`a has m`) bookkeeping, checked by the type checker ----

# (A4a: the built-in types have only their A3 members in the solver's table, `compare` at Int; `encode` etc. at
# built-in types come with A4b to A4d, so the element type here is a custom type that derives them)
case("ok-constraint-use", "RUN", "c", "", {"Main.elm": worker(TREE + EMAIL + """
cmpInts : Tree Int -> Tree Int -> Order
cmpInts = Tree.compare

encEmails : Tree Email -> Json.Encode.Value
encEmails = Tree.encode

decEmails : Json.Decode.Decoder (Tree Email)
decEmails = Tree.decoder

hashEmails : Tree Email -> Int
hashEmails = Tree.hash

mapped : (Int -> String) -> Tree Int -> Tree String
mapped = Tree.map

generic : Tree a -> Tree a -> Order
    where
        a has compare : a -> a -> Order
generic = Tree.compare
""", "1", imports="import Json.Encode\nimport Json.Decode\n")}, C_JSON, "r: 1\n")
case("ok-phantom", "RUN", "c", "", {"Main.elm": worker("""
type Id a = Id Int where derive compare, encode

cmpFns : Id (Int -> Int) -> Id (Int -> Int) -> Order
cmpFns = Id.compare

anyId : Id a -> Id a -> Order
anyId = Id.compare
""", "1")}, C_JSON, "r: 1\n")
case("constraint-function", "REJECT", "NO MEMBER", "", {"Main.elm": worker(TREE + """
bad : Tree (Int -> Int) -> Tree (Int -> Int) -> Order
bad = Tree.compare
""", "1")}, {"deps": [JSON]})
case("constraint-missing", "REJECT", "MISSING CONSTRAINT", "", {"Main.elm": worker(TREE + """
generic : Tree a -> Tree a -> Order
generic = Tree.compare
""", "1")}, {"deps": [JSON]})
case("constraint-signature", "REJECT", "TYPE MISMATCH", "", {"Main.elm": worker(TREE + """
wrong : Tree Int -> Int
wrong = Tree.compare
""", "1")}, {"deps": [JSON]})

case("ok-two-params", "RUN", "c", "", {"Main.elm": worker("""
type Pair k v = Pair k v (List ( k, v )) where derive compare, hash, toString, encode, decoder, map

cmp : Pair Int Int -> Pair Int Int -> Order
cmp = Pair.compare
""", "1")}, C_JSON, "r: 1\n")
# A4a: an operator at a parametric type needs a constrained `compare` in A3's operator path (A3b, before A4b): Elm's report
case("operator-param-not-yet", "REJECT", "TYPE MISMATCH", "Tree", {"Main.elm": worker(TREE, "Node Leaf 1 Leaf < Leaf")}, {"deps": [JSON]})
# A4a: the built-in types do not have `encode` etc. in the solver's table yet (A4b to A4d)
case("constraint-builtin-not-yet", "REJECT", "NO MEMBER", "", {"Main.elm": worker(TREE + """
encStrings : Tree String -> Json.Encode.Value
encStrings = Tree.encode
""", "1", imports="import Json.Encode\n")}, {"deps": [JSON]})

# ---- G70: the members of an opaque type follow its name ----

case("ok-opaque", "RUN", "c", "", {
    "Email.elm": "module Email exposing (Email, make)\n\n\n" + EMAIL.strip() + "\n\n\nmake : String -> Email\nmake =\n    Email\n",
    "Main.elm": worker("""
cmp : Email -> Email -> Order
cmp = Email.compare

enc : Email -> Json.Encode.Value
enc = Email.Email.encode
""", "1", imports="import Email exposing (Email)\nimport Json.Encode\n")}, C_JSON, "r: 1\n")
case("ok-cross-module", "RUN", "c", "", {
    "Email.elm": "module Email exposing (Email, make)\n\n\n" + EMAIL.strip() + "\n\n\nmake : String -> Email\nmake =\n    Email\n",
    "Main.elm": worker("""
type Contact = Contact { email : Email, tags : List String } where derive compare, hash, encode, decoder
""", "1", imports="import Email exposing (Email)\n")}, C_JSON, "r: 1\n")

# ---- uses: the C generator refuses a derived member (bodies come with A4b to A4f) ----

case("c-use-refused", "REJECTC", "", "`Color.compare` is not generated yet", {"Main.elm": worker(COLOR, "Color.compare Red Blue")}, C_JSON)
case("c-operator-refused", "REJECTC", "", "`Color.compare` is not generated yet", {"Main.elm": worker(COLOR, "Red < Blue")}, C_JSON)
case("c-enum-refused", "REJECTC", "", "`Color.enumerate` is not generated yet", {"Main.elm": worker(COLOR, "List.length Color.enumerate")}, C_JSON)

# ---- the JavaScript output refuses any program with a derive line ----

case("js-refused", "REJECT", "DERIVED MEMBERS", "Main.Color derives compare, hash", {"Main.elm": worker("""
type Color = Red | Blue where derive compare, hash
""", "1")})
case("js-refused-module", "REJECT", "DERIVED MEMBERS", "Email.Email derives compare", {
    "Email.elm": "module Email exposing (Email, make)\n\n\ntype Email = Email String where derive compare\n\n\nmake : String -> Email\nmake =\n    Email\n",
    "Main.elm": worker("", '1', imports="import Email\n")})
case("js-plain", "RUN", "js+c", "", {"Main.elm": worker("""
type Color = Red | Blue

derive : Int -> Int
derive n = n + 1
""", "derive 1")}, {}, "r: 2\n")

# ---- syntax ----

def syn(cid, line, text=""):
    case(cid, "REJECT", "UNFINISHED DERIVE LINE", text, {"Main.elm": worker("""
type Color
    = Red
    | Blue
    where
        %s
""" % line, "1")})


syn("syn-empty", "derive")
syn("syn-trailing-comma", "derive compare,")
syn("syn-upper", "derive Compare")
syn("syn-no-comma", "derive compare hash", "a comma")
syn("syn-member-named-derive", "derive : Int")
syn("syn-qualified", "derive Basics.compare")
case("syn-alias", "REJECT", "MEMBERS ON A TYPE ALIAS", "", {"Main.elm": worker("""
type alias Point =
    { x : Int }
    where
        derive compare
""", "1")})

# ---- canonical checks ----

def bad(cid, title, decls, text="", meta=None, files=None, imports=""):
    fs = dict(files or {})
    fs["Main.elm"] = worker(decls, "1", imports=imports)
    case(cid, "REJECT", title, text, fs, meta)


bad("unknown-member", "UNKNOWN DERIVED MEMBER", "type Color = Red | Blue where derive compare, frobnicate", "frobnicate")
bad("unknown-decode", "UNKNOWN DERIVED MEMBER", "type Color = Red | Blue where derive decode", "decoder")
bad("unknown-eq", "UNKNOWN DERIVED MEMBER", "type Color = Red | Blue where derive eq", "eq")
bad("twice-list", "DERIVED TWICE", "type Color = Red | Blue where derive compare, hash, compare", "compare")
bad("twice-lines", "DERIVED TWICE", """
type Color
    = Red
    | Blue
    where
        derive compare
        derive hash
""")
bad("derive-and-define", "DERIVE AND DEFINE", """
type Color
    = Red
    | Blue
    where
        derive compare, hash

        compare : Color -> Color -> Order
        compare _ _ = EQ
""", "compare")
bad("shadowed-same-name", "DERIVE SHADOWED", "", "toString", files={"Username.elm": """module Username exposing (Username, make)


type Username = Username String where derive compare, toString


make : String -> Username
make =
    Username


toString : Username -> String
toString (Username s) =
    s
"""}, imports="import Username\n")
bad("shadowed-exposed", "DERIVE SHADOWED", "", "encode", meta={"deps": [JSON]}, files={"Shapes.elm": """module Shapes exposing (..)

import Json.Encode


type Shape = Dot | Line where derive encode


encode : Int -> Json.Encode.Value
encode =
    Json.Encode.int
"""}, imports="import Shapes\n")
bad("cannot-function", "CANNOT DERIVE", "type Handler = Handler (Int -> Int) where derive compare", "Handler")
bad("cannot-function-toString", "CANNOT DERIVE", "type Handler = Handler String (Int -> Int) where derive toString", "Int -> Int")
bad("cannot-record-field", "CANNOT DERIVE", """
type Email = Email String

type Contact = Contact { email : Email, name : String } where derive compare
""", "email")
bad("cannot-deep", "CANNOT DERIVE", """
type Email = Email String

type Contact = Contact (List ( Int, Maybe Email )) where derive hash
""", "Email")
bad("cannot-json-compare", "CANNOT DERIVE", "type Payload = Payload Json.Encode.Value where derive compare",
    "Value", meta={"deps": [JSON]}, imports="import Json.Encode\n")
bad("cannot-imported", "CANNOT DERIVE", "type Wallet = Wallet Money where derive encode", "Money", meta={"deps": [JSON]},
    files={"Money.elm": "module Money exposing (Money, make)\n\n\ntype Money = Money Int where derive compare\n\n\nmake : Int -> Money\nmake =\n    Money\n"},
    imports="import Money exposing (Money)\n")
bad("cannot-alias", "CANNOT DERIVE", """
type alias Callback = String -> Int

type Button = Button { label : String, onClick : Callback } where derive hash
""", "onClick")
bad("cannot-nonregular", "CANNOT DERIVE", "type Nest a = Nil | Cons a (Nest (List a)) where derive compare", "another argument")
bad("cannot-map-no-param", "CANNOT DERIVE", "type Color = Red | Blue where derive map", "parameter")
bad("cannot-several", "CANNOT DERIVE", "type Handler = Handler (Int -> Int) where derive compare, hash")
bad("non-enumeration", "DERIVE ON NON-ENUMERATION", "type Shape = Dot | Circle Float where derive minValue, succ", "Circle")
bad("non-enumeration-record", "DERIVE ON NON-ENUMERATION", "type Shape = Shape { r : Float } where derive enumerate", "Shape")
# the implicit import of Json.Encode points at `encode` in the derive line; Elm's own report is clear enough (A4a)
bad("json-not-direct", "MODULE NOT FOUND", "type Color = Red | Blue where derive encode", "elm install elm/json")


def write():
    if os.path.isdir(CASES): shutil.rmtree(CASES)
    lines = ["# id\toutcome\ttitles (REJECT) or runs (RUN)\ttext the compiler output must contain  (generated by derivegen.py)"]
    for cid, outcome, col3, col4, files, meta, out in CASE_LIST:
        d = os.path.join(CASES, cid); os.makedirs(d)
        for name, text in files.items(): open(os.path.join(d, name), "w", encoding="utf-8").write(text)
        if meta: json.dump(meta, open(os.path.join(d, "case.json"), "w"))
        if out is not None: open(os.path.join(d, "expected.out"), "w", encoding="utf-8").write(out)
        lines.append("\t".join([cid, outcome, col3, col4]))
    open(os.path.join(HERE, "expected.tsv"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
    print("%d cases written" % len(CASE_LIST))


if __name__ == "__main__":
    if "--write" in sys.argv: write()
    else: print("\n".join(c[0] for c in CASE_LIST))
