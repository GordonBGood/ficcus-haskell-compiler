#!/usr/bin/env python3
"""S5 (STAGE4-PLAN sections 8 and 15): a standalone test of the ownership convention for EVERY kernel that takes or returns a reference.

  python3 ficus-tests/kernel_tests.py --elm bin/elmficNN --elm-home H --safe tools/safe [--only String.slice,List.cons] [--out DIR] [--list]

For each kernel of the signature table (Ficus.Mono.Kernel, read by kernel_sigs.py) whose signature has a `b` or an `o`, or whose
result is a reference, there is one small program below (its own file, its own build). The program calls the kernel
  * with arguments that are unique (a fresh value that dies in the call),
  * with arguments that are shared (the value is used again after the call, and printed),
  * with the edge or failing input of the kernel where it has one (empty string, index out of range, text that is not a number, ...).
The program is compiled twice: `--no-rc` (the oracle) and `--rc` built with AddressSanitizer + UBSan, -DFIC_NO_POOL, -DFIC_STATS (leak
detection on). The counted build must print what the oracle prints, exit 0, be silent under the sanitizers and end with 0 live
objects. A test with `needle` also requires that text in the generated C (the kernel is really reached: the JsArray kernels are
only reachable through Array). A kernel of the table without a test here is a failure of this script (so a new kernel cannot be added
without one). Kernels whose arguments and result are all scalars (Basics arithmetic, Bitwise, Char) hold no reference and have no test.
Exit status 1 on any failure."""
import argparse, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import kernel_sigs  # noqa: E402

HEAD = '''module Main exposing (main)

import Array exposing (Array)
%s

-- a fresh heap string (a literal is a static object that is never freed)
mk : Int -> String
mk n =
    String.fromInt n ++ "x"


big : Int -> Array String
big n =
    Array.initialize n mk


emptyS : Array String
emptyS =
    Array.empty


noS : List String
noS =
    []

%s
main : Program () () ()
main =
    Platform.worker
        { init =
            \\_ ->
                let
%s                in
                if String.length (%s) > 0 then
                    ( (), Cmd.none )

                else
                    ( (), Cmd.none )
        , update = \\_ m -> ( m, Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }
'''

PARSER = "import Parser exposing ((|.), (|=), Parser)"
RUNP = '''
run : Parser a -> String -> Maybe a
run p s =
    Result.toMaybe (Parser.run p s)
'''

# kernel -> (expressions, options). An expression may span lines (it is indented by the driver). Options: imports, decls, needle, crash.
T = {}


def t(kernel, exprs, **opt):
    T[kernel] = (exprs, opt)


S = "elm/core:String."
t("elm/core:Basics.append", ['mk 1 ++ mk 2', 'let a = mk 3 in ( a ++ a, a )', '"" ++ mk 4', 'mk 5 ++ ""'])
t("elm/core:Basics.append/list", ['List.range 1 3 ++ List.range 4 6', 'let a = [ mk 1, mk 2 ] in ( a ++ a, a )', '[] ++ [ mk 3 ]', '[ mk 4 ] ++ []',
                                  'let a = [ mk 5 ] in ( a ++ [ mk 6 ], [ mk 7 ] ++ a, a )'])
t("elm/core:List.cons", ['1 :: List.range 2 4', 'let a = [ mk 1 ] in ( mk 2 :: a, a )', 'let s = mk 3 in ( s :: [], s :: [ s ], s )'])
J = "elm/core:Elm.JsArray."
t(J + "empty", ['Array.toList emptyS', 'Array.length (Array.push (mk 1) Array.empty)'], needle="fic_ja_empty")
t(J + "singleton", ['Array.toList (Array.push (mk 0) (big 32))', 'let a = big 64 in ( Array.length (Array.push (mk 1) a), Array.length a )',
                    'Array.toList (Array.slice 1 40 (big 70))'], needle="fic_ja_singleton")
t(J + "length", ['Array.length (big 5)', 'let a = big 40 in ( Array.length a, Array.get 39 a )', 'Array.length emptyS'], needle="fic_ja_length")
t(J + "initialize", ['Array.toList (Array.initialize 3 mk)', 'Array.length (Array.initialize 100 mk)', 'Array.toList (Array.initialize 0 mk)',
                     'let f = \\i -> mk (i * 2) in ( Array.toList (Array.initialize 2 f), f 1 )'], needle="fic_ja_initialize(")
t(J + "initializeFromList", ['Array.toList (Array.fromList [ mk 1, mk 2 ])', 'let l = List.map mk (List.range 1 70) in ( Array.length (Array.fromList l), List.length l )',
                             'Array.toList (Array.fromList noS)'], needle="fic_jafl_")
t(J + "unsafeGet", ['Array.get 1 (big 3)', 'let a = big 50 in ( ( Array.get 40 a, Array.get 2 a ), Array.get 99 a, Array.length a )', 'Array.get 0 emptyS'],
  needle="fic_ja_get")
t(J + "unsafeSet", ['Array.toList (Array.set 1 (mk 9) (big 3))', 'let a = big 3 in ( Array.toList (Array.set 0 (mk 8) a), Array.toList a )',
                    'let a = big 70 in ( Array.get 5 (Array.set 5 (mk 7) a), Array.get 5 a )', 'Array.toList (Array.set 9 (mk 6) (big 2))',
                    'let s = mk 5 in ( Array.toList (Array.set 0 s (Array.set 1 s (big 2))), s )'], needle="fic_ja_set")
# S6: the take is made by the Rc pass from the unsafeGet of Array.setHelp and insertTailInTree (arrays with a tree: more than 32 elements)
t(J + "unsafeTake", ['Array.get 40 (Array.set 40 (mk 9) (big 70))', 'let a = big 70 in ( Array.get 40 (Array.set 40 (mk 8) a), Array.get 40 a )',
                     'Array.get 1500 (Array.set 1500 (mk 7) (big 2000))',
                     'let a = big 2000 in ( Array.get 1100 (Array.set 1100 (mk 6) a), Array.get 1100 a, Array.length a )',
                     'Array.length (List.foldl Array.push (big 1) (List.map mk (List.range 1 1100)))',
                     'let a = big 1100 in ( Array.length (Array.push (mk 5) a), Array.get 1099 a )'], needle="fic_ja_take")
t(J + "push", ['Array.toList (Array.push (mk 9) (big 2))', 'let a = big 2 in ( Array.toList (Array.push (mk 8) a), Array.toList a )',
               'Array.length (List.foldl Array.push (big 1) (List.map mk (List.range 1 80)))', 'let s = mk 7 in ( Array.toList (Array.push s (Array.push s Array.empty)), s )'],
  needle="fic_ja_push")
t(J + "foldl", ['Array.foldl (\\s acc -> acc ++ s) "" (big 4)', 'let a = big 40 in ( Array.foldl (\\s n -> n + String.length s) 0 a, Array.length a )',
                'Array.foldl (\\s acc -> s :: acc) [] (big 3)', 'Array.foldl (\\s acc -> acc ++ s) (mk 1) emptyS'], needle="fic_ja_foldl")
t(J + "foldr", ['Array.foldr (\\s acc -> acc ++ s) "" (big 4)', 'let a = big 40 in ( Array.toList a |> List.length, Array.foldr (\\s acc -> s :: acc) [] a |> List.length )',
                'Array.foldr (\\s acc -> acc ++ s) (mk 1) emptyS'], needle="fic_ja_foldr")
t(J + "map", ['Array.toList (Array.map (\\s -> s ++ "!") (big 3))', 'let a = big 40 in ( Array.length (Array.map String.length a), Array.get 3 a )',
              'Array.toList (Array.map String.length emptyS)'], needle="fic_ja_map")
t(J + "indexedMap", ['Array.toList (Array.indexedMap (\\i s -> String.fromInt i ++ s) (big 3))',
                     'let a = big 40 in ( Array.get 35 (Array.indexedMap (\\i s -> ( i, s )) a), Array.get 35 a )'], needle="fic_ja_indexedmap")
t(J + "slice", ['Array.toList (Array.slice 1 3 (big 5))', 'let a = big 70 in ( Array.toList (Array.slice 30 36 a), Array.length a )',
                'Array.toList (Array.slice 4 2 (big 5))', 'Array.toList (Array.slice -2 99 (big 5))'], needle="fic_ja_slice")
t(J + "appendN", ['Array.toList (Array.append (big 2) (big 3))', 'let a = big 40 in ( Array.length (Array.append a a), Array.length a )',
                  'Array.toList (Array.append (big 2) Array.empty)', 'Array.length (Array.append (big 33) (big 70))'], needle="fic_ja_appendn")

t(S + "length", ['String.length (mk 12)', 'let s = mk 3 in ( String.length s, s )', 'String.length ""'])
t(S + "slice", ['String.slice 1 3 (mk 12345)', 'let s = mk 12345 in ( String.slice 0 2 s, String.slice -2 99 s, s )', 'String.slice 5 2 (mk 1)', 'String.slice 0 0 ""',
                 # FIX2 step 3: a long non ASCII string (the position cache), seeks forwards, backwards, to the end; an ASCII one (offset = index)
                 'let s = String.join "" (List.repeat 30 "é日😀") ++ mk 7 in ( String.slice 10 14 s, String.slice 3 5 s, ( String.slice -4 99 s, String.slice 0 2 s ) ) |> \\r -> ( r, String.slice 80 91 s, ( String.slice 85 86 s, s ) )',
                 'let s = String.join "" (List.repeat 60 "abc") ++ mk 7 in ( String.slice 100 104 s, String.slice 3 5 s, ( String.slice -4 99 s, String.left 3 s, ( String.dropRight 170 s, s ) ) )'])
t(S + "cons", ["String.cons 'a' (mk 1)", "let s = mk 2 in ( String.cons 'b' s, s )", "String.cons 'c' \"\""])
t(S + "join", ['String.join (mk 0) [ mk 1, mk 2, mk 3 ]', 'let l = [ mk 1, mk 2 ] in let sep = mk 9 in ( String.join sep l, l, sep )', 'String.join (mk 1) []'])
t(S + "words", ['String.words (mk 1 ++ " " ++ mk 2)', 'let s = "a  b " ++ mk 3 in ( String.words s, s )', 'String.words ""'])
t(S + "toUpper", ['String.toUpper (mk 1)', 'let s = mk 2 in ( String.toUpper s, s )', 'String.toUpper ""'])
t(S + "toLower", ['String.toLower (mk 1 ++ "ABC")', 'let s = mk 2 ++ "Q" in ( String.toLower s, s )', 'String.toLower ""'])
t(S + "map", ["String.map (\\c -> if c == 'x' then 'y' else c) (mk 1)", "let s = mk 2 in ( String.map Char.toUpper s, s )", 'String.map Char.toUpper ""'])
t(S + "foldl", ['String.foldl (\\c acc -> String.cons c acc) "" (mk 123)', 'let s = mk 45 in ( String.foldl (\\c n -> n + Char.toCode c) 0 s, s )',
                'String.foldl (\\c acc -> c :: acc) [] (mk 6)', 'String.foldl String.cons (mk 7) ""'])
t(S + "foldr", ['String.foldr (\\c acc -> String.cons c acc) "" (mk 123)', 'let s = mk 45 in ( String.foldr (\\c acc -> c :: acc) [] s, s )', 'String.foldr String.cons (mk 7) ""'])
t(S + "fromList", ["String.fromList [ 'a', 'b' ]", "let l = String.toList (mk 12) in ( String.fromList l, l )", 'String.fromList []'])
t(S + "append", ['String.append (mk 1) (mk 2)', 'let a = mk 3 in ( String.append a a, a )', 'String.append "" ""'])
t(S + "contains", ['String.contains "x" (mk 1)', 'let a = mk 12 in let b = mk 2 in ( String.contains b a, a, b )', 'String.contains "" ""'])
t(S + "startsWith", ['String.startsWith "1" (mk 1)', 'let a = mk 12 in let b = mk 12 in ( String.startsWith b a, a, b )', 'String.startsWith "q" ""'])
t(S + "endsWith", ['String.endsWith "x" (mk 1)', 'let a = mk 12 in let b = mk 2 in ( String.endsWith b a, a, b )', 'String.endsWith "q" ""'])
t(S + "indexes", ['String.indexes "x" (mk 1 ++ mk 2)', 'let a = mk 1 ++ mk 1 in let b = mk 1 in ( String.indexes b a, a, b )', 'String.indexes "" (mk 1)',
                  'let s = String.join "" (List.repeat 30 "é日😀") ++ mk 7 in ( String.indexes "日" s, String.indexes "😀é" s, s )', 'String.indexes "ab" (String.join "" (List.repeat 40 "abab"))'])
t(S + "indices", ['String.indices "x" (mk 1 ++ mk 2)', 'let a = mk 1 ++ mk 1 in let b = mk 1 in ( String.indices b a, a, b )', 'String.indices "q" ""'])
t(S + "split", ['String.split "x" (mk 1 ++ mk 2)', 'let a = mk 1 ++ mk 1 in let b = "1" ++ "" in ( String.split b a, a, b )', 'String.split "" (mk 12)', 'String.split "q" ""'])
t(S + "lines", ['String.lines (mk 1 ++ "\\n" ++ mk 2)', 'let s = mk 1 ++ "\\r\\n" in ( String.lines s, s )', 'String.lines ""'])
t(S + "reverse", ['String.reverse (mk 123)', 'let s = mk 45 in ( String.reverse s, s )', 'String.reverse ""'])
t(S + "trim", ['String.trim ("  " ++ mk 1 ++ " ")', 'let s = " " ++ mk 2 in ( String.trim s, s )', 'String.trim "   "'])
t(S + "trimLeft", ['String.trimLeft ("  " ++ mk 1 ++ " ")', 'let s = " " ++ mk 2 in ( String.trimLeft s, s )', 'String.trimLeft ""'])
t(S + "trimRight", ['String.trimRight ("  " ++ mk 1 ++ " ")', 'let s = mk 2 ++ " " in ( String.trimRight s, s )', 'String.trimRight ""'])
t(S + "uncons", ['String.uncons (mk 1)', 'let s = mk 2 in ( String.uncons s, s )', 'String.uncons ""', 'String.uncons (String.fromChar \'z\')'])
t(S + "filter", ['String.filter Char.isDigit (mk 123)', 'let s = mk 45 in ( String.filter (\\c -> c /= \'4\') s, s )', 'String.filter Char.isDigit ""'])
t(S + "any", ['String.any Char.isDigit (mk 1)', 'let s = mk 2 in ( String.any Char.isUpper s, s )', 'String.any Char.isDigit ""'])
t(S + "all", ['String.all Char.isDigit (mk 1)', 'let s = mk 2 in ( String.all Char.isAlphaNum s, s )', 'String.all Char.isDigit ""'])
t(S + "toInt", ['String.toInt (String.fromInt 123 ++ "")', 'let s = mk 4 in ( String.toInt s, s )', 'String.toInt ""', 'String.toInt ("-" ++ String.fromInt 77)'])
t(S + "toFloat", ['String.toFloat (String.fromInt 12 ++ ".5")', 'let s = mk 4 in ( String.toFloat s, s )', 'String.toFloat ""'])
t(S + "fromInt", ['String.fromInt 12345', 'let s = String.fromInt -7 in ( s, s ++ s )', 'String.length (String.fromInt 0)'])
t(S + "fromFloat", ['String.fromFloat 1.5', 'let s = String.fromFloat -0.25 in ( s, s ++ s )', 'String.length (String.fromFloat 100)'])

P = "elm/parser:Parser.Advanced."
popt = dict(imports=PARSER, decls=RUNP, parser=True)
t(P + "isSubString", ['run (Parser.token "1x") (mk 1)', 'let s = mk 22 in ( run (Parser.symbol "22") s, run (Parser.keyword "22x") s, s )', 'run (Parser.token "q") ""',
                      'run (Parser.succeed () |. Parser.token (mk 3) |. Parser.token (mk 4)) (mk 3 ++ mk 4)'], **popt)
t(P + "findSubString", ['run (Parser.getChompedString (Parser.chompUntil "x")) (mk 123)', 'let s = mk 5 ++ mk 6 in ( run (Parser.getChompedString (Parser.chompUntil "6")) s, s )',
                        'run (Parser.chompUntil "q") (mk 1)', 'run (Parser.chompUntilEndOr "q") (mk 1)'], **popt)
t(P + "isSubChar", ['run (Parser.getChompedString (Parser.chompWhile Char.isDigit)) (mk 123)', 'let s = mk 5 in ( run (Parser.chompIf Char.isDigit) s, run (Parser.chompIf Char.isUpper) s, s )',
                    'run (Parser.chompIf Char.isDigit) ""', 'run (Parser.getChompedString (Parser.chompWhile (\\c -> c /= \'\\n\'))) (mk 1 ++ "\\n" ++ mk 2)'], **popt)
t(P + "isAsciiCode", ['run Parser.float (String.fromInt 12 ++ ".5e1")', 'let s = String.fromInt 3 ++ "e2" in ( run Parser.float s, s )', 'run Parser.float (mk 1)', 'run Parser.float ""'], **popt)
t(P + "chompBase10", ['run Parser.int (String.fromInt 123 ++ "")', 'let s = String.fromInt 45 ++ " " in ( run Parser.int s, run Parser.int s, s )', 'run Parser.int (mk 1)', 'run Parser.int ""'], **popt)
NUM = 'Parser.number { int = Just identity, hex = Just identity, octal = Just identity, binary = Just identity, float = Nothing }'
t(P + "consumeBase", ['run (%s) ("0o" ++ String.fromInt 17)' % NUM, 'let s = "0b" ++ String.fromInt 101 in ( run (%s) s, s )' % NUM, 'run (%s) ("0o" ++ mk 9)' % NUM], **popt)
t(P + "consumeBase16", ['run (%s) ("0x" ++ String.fromInt 1 ++ "F")' % NUM, 'let s = "0x" ++ String.fromInt 10 in ( run (%s) s, s )' % NUM, 'run (%s) ("0x" ++ "zz")' % NUM], **popt)
# the one entry string cache of the parser kernels: alternate two strings, a string that dies while it is cached, one cached twice
t("parser string cache", ['let a = mk 111 in let b = mk 222 in ( ( run Parser.int a, run Parser.int b ), run Parser.int a, ( a, b ) )',
                          'List.map (\\i -> run Parser.int (String.fromInt i ++ "")) (List.range 1 5)',
                          'let s = mk 7 in ( run (Parser.getChompedString (Parser.chompWhile Char.isDigit)) s, run (Parser.getChompedString (Parser.chompWhile Char.isDigit)) s )'], **popt)

D = "elm/core:Debug."
t(D + "log", ['Debug.log (mk 1) (mk 2)', 'let s = mk 3 in ( Debug.log "shared" s, s )', 'Debug.log "list" [ mk 4, mk 5 ]', 'Debug.log "" ( 1, Just (mk 6) )'])
t(D + "toString", ['Debug.toString (mk 1)', 'let l = [ Just (mk 2), Nothing ] in ( Debug.toString l, l )', 'Debug.toString ( 1.5, \'c\', [ () ] )', 'Debug.toString (big 3)'])
t(D + "todo", ['if String.length (mk 1) > 99 then Debug.todo (mk 2) else mk 3', 'let s = mk 4 in if String.isEmpty s then Debug.todo s else s'])
t(D + "todo/crash", ['let s = mk 4 in if String.length s > 0 then Debug.todo (s ++ " reached") else s'], crash="4x reached")
t("elm/core:Platform.worker", ['mk 1'])
t("elm/core:Platform.Cmd.none", ['mk 1'])
t("elm/core:Platform.Sub.none", ['mk 1'])
CMP = ['{op} (mk 1) (mk 2)', 'let a = mk 3 in ( {op} a a, a )', '{op} [ mk 1, mk 2 ] [ mk 1 ]', 'let l = [ ( 1, mk 4 ) ] in ( {op} l l, {op} l [], l )', '{op} "" ""']
EQ = CMP + ['let r = { n = mk 5, m = Just [ mk 6 ] } in ( {op} r r, {op} r { r | n = "" }, r.n )', '{op} (Ok (mk 7)) (Err 1)', '{op} (big 3) (big 3)']
for name, op, lst in (("eq", "(==)", EQ), ("neq", "(/=)", EQ), ("gt", "(>)", CMP), ("ge", "(>=)", CMP), ("lt", "(<)", CMP), ("le", "(<=)", CMP), ("compare", "compare", CMP)):
    t("elm/core:Basics." + name, [e.replace("{op}", op) for e in lst])

# ---- elm/json (runtime/fic_json.h, overlay/FicOverlayJson.elm) ----
JSON = "import Dict\nimport Json.Decode as D\nimport Json.Encode as E\nimport Set"
JDECL = """
dec : D.Decoder a -> String -> Result String a
dec d s =
    Result.mapError D.errorToString (D.decodeString d s)


q : String -> String
q s =
    "\\"" ++ s ++ "\\""


js : Int -> String
js n =
    "[" ++ String.fromInt n ++ "," ++ q (mk n) ++ ",{" ++ q "k" ++ ":[" ++ q (mk (n + 1)) ++ "]}]"


enc : E.Value -> String
enc =
    E.encode 0
"""
jopt = dict(imports=JSON, decls=JDECL, deps=["elm/json"])
JE = "elm/json:Json.Encode."
JD = "elm/json:Json.Decode."
JO = "author/project:FicOverlayJson."
t(JE + "encode", ['E.encode 0 (E.string (mk 1))', 'let v = E.list E.string [ mk 1, mk 2 ] in ( E.encode 2 v, E.encode 0 v )', 'E.encode 4 (E.object [])',
                  'E.encode 3 (E.object [ ( mk 1, E.list E.int [ 1, 2 ] ), ( "f", E.float 1.5 ), ( "n", E.float (0 / 0) ) ])'], needle="fic_json_encode", **jopt)
t(JE + "string", ['enc (E.string (mk 1))', 'let s = mk 2 in ( enc (E.string s), s )', 'E.string (mk 3) == E.string (mk 3)', 'enc (E.string "")'], **jopt)
t(JE + "int", ['enc (E.int 5)', 'let v = E.int -7 in ( enc v, v == v, v == E.float -7 )'], needle="fic_json_int", **jopt)
t(JE + "float", ['enc (E.float 1.5)', 'let v = E.float 1.0e21 in ( enc v, v == v )', 'enc (E.float (1 / 0))'], needle="fic_json_float", **jopt)
t(JE + "bool", ['enc (E.bool True)', 'let v = E.bool False in ( enc v, v == v, v == E.bool True )'], needle="fic_json_bool", **jopt)
t(JE + "null", ['enc E.null', 'let v = E.null in ( enc v, v == v, enc (E.list identity [ v, v ]) )'], needle="fic_json_null", **jopt)
t(JO + "arrayFrom", ['enc (E.list E.string [ mk 1, mk 2 ])', 'let l = [ mk 1 ] in ( enc (E.list E.string l), l )', 'enc (E.list E.int [])', 'enc (E.array E.string (big 3))',
                     'enc (E.set E.string (Set.fromList [ mk 2, mk 1 ]))', 'let v = E.string (mk 4) in ( enc (E.list identity [ v, v ]), enc v )'], needle="fic_json_array_from", **jopt)
t(JO + "objectFrom", ['enc (E.object [ ( mk 1, E.string (mk 2) ), ( mk 3, E.int 4 ) ])',
                      'let v = E.string (mk 5) in ( enc (E.object [ ( "a", v ), ( "a", E.null ), ( "b", v ), ( "a", v ) ]), enc v )',
                      'enc (E.dict identity E.string (Dict.fromList [ ( mk 1, mk 2 ), ( mk 0, mk 3 ) ]))', 'enc (E.object [])',
                      'E.object [ ( mk 1, E.int 1 ), ( mk 2, E.int 2 ) ] == E.object [ ( mk 2, E.int 2 ), ( mk 1, E.int 1 ) ]'], needle="fic_json_object_from", **jopt)
t(JO + "objectKeys", ['dec (D.keyValuePairs D.string) ("{" ++ q (mk 1) ++ ":" ++ q (mk 2) ++ "}")', 'dec (D.keyValuePairs D.int) (js 1)',
                      'let d = D.keyValuePairs D.int in ( dec d "{}", dec d "{\\"a\\":1,\\"b\\":2}" )'], needle="FIC_JD_KEYS", **jopt)
t(JO + "objectValues", ['dec (D.dict D.string) ("{" ++ q (mk 1) ++ ":" ++ q (mk 2) ++ "}")',
                        'dec (D.keyValuePairs D.string) ("{\\"a\\":" ++ q (mk 1) ++ ",\\"b\\":" ++ q (mk 2) ++ ",\\"c\\":3}")',
                        'let d = D.keyValuePairs (D.list D.string) in ( dec d "{\\"a\\":[\\"x\\"]}", dec d "{}", dec d "[]" )'], needle="FIC_JD_VALUES", **jopt)
t(JO + "arrayAsList", ['dec (D.array D.string) ("[" ++ q (mk 1) ++ "]")', 'dec (D.array D.string) ("[" ++ q (mk 1) ++ ",2]")', 'dec (D.array D.int) "{}"',
                       'let d = D.array D.int in ( dec d "[1,2]", dec d "[]" )'], needle="FIC_JD_ARRAY", **jopt)
t(JD + "string", ['dec D.string (q (mk 1))', 'dec D.string "1"', 'let d = D.string in ( dec d "\\"a\\"", dec d "\\"b\\"" )'], needle="FIC_JD_STRING", **jopt)
t(JD + "bool", ['dec D.bool "true"', 'dec D.bool (q (mk 1))', 'let d = D.bool in ( dec d "false", dec d "0" )'], needle="FIC_JD_BOOL", **jopt)
t(JD + "int", ['dec D.int "9007199254740993"', 'dec D.int (q (mk 1))', 'let d = D.int in ( dec d "1e3", dec d "1.5", dec d "-0" )'], needle="FIC_JD_INT", **jopt)
t(JD + "float", ['dec D.float "1.5"', 'dec D.float (q (mk 1))', 'let d = D.float in ( dec d "3", dec d "1e400", dec d "null" )'], needle="FIC_JD_FLOAT", **jopt)
t(JD + "value", ['Result.map enc (dec D.value (js 1))', 'let r = dec D.value (js 2) in ( Result.map enc r, r == r )',
                 'let d = D.value in ( Result.map enc (dec d "null"), Result.map enc (dec (D.index 1 d) (js 3)) )'], needle="FIC_JD_VALUE", **jopt)
t(JD + "null", ['dec (D.null (mk 1)) "null"', 'dec (D.null (mk 2)) "1"', 'let d = D.null ( 1, mk 3 ) in ( dec d "null", dec d "null" )', 'dec (D.nullable D.string) "null"',
                'dec (D.null 7) "null"', 'D.null (mk 1) == D.null (mk 1)'], needle="FIC_JD_NULL", **jopt)
t(JD + "list", ['dec (D.list D.string) ("[" ++ q (mk 1) ++ "," ++ q (mk 2) ++ "]")', 'dec (D.list D.string) ("[" ++ q (mk 1) ++ "," ++ q (mk 2) ++ ",3]")',
                'dec (D.list D.int) "[1,2,3]"', 'dec (D.list D.float) "[1.5]"', 'dec (D.list D.bool) "[true,false]"', 'dec (D.list (D.succeed ())) "[1]"',
                'dec (D.list (D.map (\\s -> ( s, 1 )) D.string)) "[\\"a\\"]"', 'dec (D.list D.int) "{}"', 'dec (D.list (D.map Char.fromCode D.int)) "[97,98]"',
                'let d = D.list (D.list D.string) in ( dec d "[[\\"a\\"],[]]", dec d "[[\\"a\\"],[1]]" )'], needle="FIC_JD_LIST", **jopt)
t(JD + "field", ['dec (D.field (mk 1) D.string) ("{" ++ q (mk 1) ++ ":" ++ q (mk 2) ++ "}")', 'dec (D.field (mk 1) D.string) "{}"', 'dec (D.field (mk 1) D.string) ("{" ++ q (mk 1) ++ ":1}")',
                 'dec (D.at [ "a", "b" ] D.string) "{\\"a\\":{\\"b\\":\\"c\\"}}"', 'let d = D.field "a" D.int in ( dec d "{\\"a\\":1}", dec d "[]", d == d )'], needle="fic_jd_field", **jopt)
t(JD + "index", ['dec (D.index 1 D.string) (js 1)', 'dec (D.index 9 D.string) (js 1)', 'dec (D.index -1 D.string) (js 1)', 'dec (D.index 0 D.string) (js 1)',
                 'let d = D.index 0 D.int in ( dec d "[5]", dec d "{}", d == D.index 1 D.int )'], needle="fic_jd_index", **jopt)
t(JD + "oneOf", ['dec (D.oneOf [ D.string, D.map String.fromInt D.int ]) (q (mk 1))', 'dec (D.oneOf [ D.string, D.map String.fromInt D.int ]) "5"',
                 'dec (D.oneOf [ D.string, D.map String.fromInt D.int ]) "true"', 'dec (D.oneOf [ D.fail (mk 1), D.fail (mk 2) ]) "1" |> Result.map ((+) 1)',
                 'let ds = [ D.string, D.map String.fromInt D.int ] in ( dec (D.oneOf ds) "1", dec (D.oneOf ds) "true", List.length ds )',
                 'D.oneOf [ D.int ] == D.oneOf [ D.int, D.int ]'], needle="fic_jd_oneof", **jopt)
t(JD + "map", ['dec (D.map (\\s -> s ++ mk 1) D.string) "\\"a\\""', 'dec (D.map (\\s -> s ++ mk 1) D.string) "1"',
               'let f = String.append (mk 2) in ( dec (D.map f D.string) "\\"a\\"", f "z" )', 'dec (D.map (\\n -> ( n, mk n )) D.int) "3"', 'dec (D.map String.length D.string) (q (mk 5))',
               'let d = D.map mk D.int in ( dec d "1", dec d "2", dec (D.list d) "[3,4]" )'], needle="fic_jd_map1", **jopt)
M2 = 'D.map2 (\\a b -> a ++ b) (D.index 0 D.string) (D.index 1 D.string)'
t(JD + "map2", ['dec (%s) ("[" ++ q (mk 1) ++ "," ++ q (mk 2) ++ "]")' % M2, 'dec (%s) ("[1," ++ q (mk 2) ++ "]")' % M2, 'dec (%s) ("[" ++ q (mk 1) ++ ",2]")' % M2,
                'dec (D.map3 (\\a b c -> [ a, b, c ]) (D.index 0 D.string) (D.index 1 D.string) (D.index 2 D.string)) ("[" ++ q (mk 1) ++ "," ++ q (mk 2) ++ "," ++ q (mk 3) ++ "]")',
                'dec (D.map3 (\\a b c -> [ a, b, c ]) (D.index 0 D.string) (D.index 1 D.string) (D.index 2 D.string)) ("[" ++ q (mk 1) ++ "," ++ q (mk 2) ++ ",3]")',
                'dec (D.map8 (\\a b c d e f g h -> ( [ a, b, c, d ], e + f, [ g, h ] )) D.string D.string D.string D.string (D.succeed 1) (D.succeed 2) D.string D.string) (q (mk 4))',
                'let d = D.map2 Tuple.pair D.int D.int in ( dec d "1", dec d "true" )'], needle="fic_jd_map2", **jopt)
t(JD + "decodeString", ['dec D.value (js 1) |> Result.map enc', 'dec D.int "{"', 'dec D.int ""', 'dec D.string "\\"a\\\\u00e9\\\\ud83d\\\\ude23\\\\n\\\\ud800x\\""',
                        'dec D.value ("[1,{\\"a\\":[" ++ q (mk 1) ++ "],\\"b\\":}]") |> Result.map enc', 'let s = js 3 in ( dec D.value s |> Result.map enc, s )',
                        'dec D.value "{\\"a\\":\\"x\\",\\"b\\":\\"y\\",\\"a\\":\\"z\\"}" |> Result.map enc', 'dec D.value " [ 1.5e2 , -0 , 12345678901234567890 , true , null ] x" |> Result.map enc',
                        'dec D.value " [ 1.5e2 , -0 , 12345678901234567890 , true , null ] " |> Result.map enc'], needle="fic_jd_decode_string", **jopt)
t(JD + "decodeValue", ['D.decodeValue D.string (E.string (mk 1)) |> Result.mapError D.errorToString',
                       'let v = E.list E.string [ mk 1, mk 2 ] in ( D.decodeValue (D.list D.string) v |> Result.mapError D.errorToString, enc v )',
                       'D.decodeValue D.int (E.string (mk 3)) |> Result.mapError D.errorToString',
                       'D.decodeValue (D.field "a" D.int) (E.object [ ( "a", E.int 9 ) ]) |> Result.mapError Debug.toString'], needle="fic_jd_decode_value", **jopt)
t(JD + "succeed", ['dec (D.succeed (mk 1)) "1"', 'let d = D.succeed [ mk 2 ] in ( dec d "1", dec d "2" )', 'dec (D.succeed 5) "{"', 'dec (D.succeed ( 1, mk 3 )) "1"',
                   'D.succeed (mk 1) == D.succeed (mk 1)', 'D.succeed 1.5 == D.succeed 2.5', "dec (D.succeed 'c') \"0\""], needle="FIC_JD_SUCCEED", **jopt)
t(JD + "fail", ['dec (D.map2 (+) D.int (D.fail (mk 1))) "1"', 'dec (D.oneOf [ D.fail (mk 2), D.int ]) "1"', 'dec (D.oneOf [ D.fail (mk 2), D.int ]) "true"',
                'let d = D.oneOf [ D.fail (mk 3), D.int ] in ( dec d "1", dec (D.list d) "[1,null]" )'], needle="fic_jd_fail", **jopt)
t(JD + "andThen", ['dec (D.string |> D.andThen (\\s -> D.succeed (s ++ mk 1))) "\\"a\\""', 'dec (D.int |> D.andThen (\\n -> if n > 0 then D.succeed (mk n) else D.fail (mk n))) "0"',
                   'dec (D.int |> D.andThen (\\n -> if n > 0 then D.succeed (mk n) else D.fail (mk n))) "4"', 'dec (D.string |> D.andThen (\\s -> D.succeed (s ++ mk 1))) "1"',
                   'dec (D.lazy (\\_ -> D.string)) "\\"a\\""', 'let d = D.string |> D.andThen (\\s -> D.map (\\n -> ( s, n )) (D.succeed 1)) in ( dec d (q (mk 2)), dec d "0" )'],
  needle="fic_jd_andthen", **jopt)

# ---- elm/bytes (runtime/fic_bytes.h, overlay/FicOverlayBytes.elm) ----
BYTES = "import Bytes exposing (Bytes, Endianness(..))\nimport Bytes.Decode as BD\nimport Bytes.Encode as BE"
BDECL = """
bs : List Int -> Bytes
bs xs =
    BE.encode (BE.sequence (List.map BE.unsignedInt8 xs))


toList : Bytes -> List Int
toList b =
    Maybe.withDefault [ -1 ] (BD.decode (BD.loop ( Bytes.width b, [] ) listStep) b)


listStep : ( Int, List Int ) -> BD.Decoder (BD.Step ( Int, List Int ) (List Int))
listStep ( n, acc ) =
    if n <= 0 then
        BD.succeed (BD.Done (List.reverse acc))

    else
        BD.map (\\x -> BD.Loop ( n - 1, x :: acc )) BD.unsignedInt8


strStep : ( Int, List String ) -> BD.Decoder (BD.Step ( Int, List String ) (List String))
strStep ( n, acc ) =
    if n <= 0 then
        BD.succeed (BD.Done (List.reverse acc))

    else
        BD.map (\\s -> BD.Loop ( n - 1, (s ++ mk n) :: acc )) (BD.string 1)
"""
bopt = dict(imports=BYTES, decls=BDECL, deps=["elm/bytes"])
BO = "author/project:FicOverlayBytes."
t("elm/bytes:Bytes.width", ['Bytes.width (bs [ 1, 2, 3 ])', 'let b = bs [ 1 ] in ( Bytes.width b, Bytes.width b, b == b )', 'Bytes.width (bs [])', 'Debug.toString (bs [ 1, 2 ])'],
  needle="fic_bytes_width", **bopt)
t("elm/bytes:Bytes.Encode.encode",
  ['toList (BE.encode (BE.sequence [ BE.signedInt8 -1, BE.signedInt16 BE -2, BE.signedInt32 LE -3, BE.unsignedInt8 4, BE.unsignedInt16 LE 5, BE.unsignedInt32 BE 6, BE.float32 BE 1.5, BE.float64 LE 2.5, BE.string (mk 7), BE.bytes (bs [ 8, 9 ]), BE.sequence [] ]))',
   'let e = BE.string (mk 1) in ( toList (BE.encode e), toList (BE.encode (BE.sequence [ e, e ])) )', 'Bytes.width (BE.encode (BE.sequence []))',
   'let b = bs [ 1, 2 ] in ( toList (BE.encode (BE.sequence [ BE.bytes b, BE.bytes b ])), toList b )', 'toList (BE.encode (BE.float32 LE 1.0e40))'], needle="fic_bytes_encode", **bopt)
t("elm/bytes:Bytes.Encode.getStringWidth", ['BE.getStringWidth (mk 1)', 'let s = mk 22 ++ "é" in ( BE.getStringWidth s, s )', 'BE.getStringWidth ""'], needle="fic_bytes_string_width", **bopt)
t(BO + "wrap", ['BD.decode (BD.succeed (mk 1)) (bs [])', 'let d = BD.succeed (mk 2) in ( BD.decode d (bs []), BD.decode d (bs [ 1 ]) )', 'BD.decode (BD.map2 (+) BD.unsignedInt8 BD.fail) (bs [ 1 ])',
                'BD.decode (BD.map (\\x -> mk x) BD.unsignedInt8) (bs [ 5 ])'], **bopt)
t(BO + "unwrap", ['BD.decode (BD.string 2) (bs [ 104, 105 ])', 'let b = bs [ 104, 105, 106 ] in ( BD.decode (BD.string 3) b, BD.decode (BD.string 4) b, Bytes.width b )',
                  'BD.decode (BD.string 1 |> BD.andThen (\\s -> BD.map (\\u -> s ++ u) (BD.string 5))) (bs [ 97, 98 ])',
                  'BD.decode (BD.string 1 |> BD.andThen (\\s -> BD.map (\\u -> s ++ u) (BD.string 1))) (bs [ 97, 98 ])',
                  'BD.decode (BD.loop ( 3, [] ) strStep) (bs [ 97, 98, 99 ])', 'BD.decode (BD.loop ( 4, [] ) strStep) (bs [ 97, 98, 99 ])',
                  'BD.decode (BD.map5 (\\a b c d e -> [ a, b, c, d, e ]) (BD.string 1) (BD.string 1) (BD.string 1) (BD.string 1) (BD.string 1)) (bs [ 97, 98, 99, 100, 101 ])',
                  'BD.decode (BD.map5 (\\a b c d e -> [ a, b, c, d, e ]) (BD.string 1) (BD.string 1) (BD.string 1) (BD.string 1) (BD.string 1)) (bs [ 97, 98, 99, 100 ])'], **bopt)
t(BO + "failure", ['BD.decode (BD.map2 (+) BD.unsignedInt8 BD.fail) (bs [ 1 ])', 'BD.decode (BD.map2 (\\a b -> a ++ b) (BD.string 1) (BD.andThen (\\_ -> BD.fail) BD.unsignedInt8)) (bs [ 97, 98 ])',
                   'BD.decode (BD.map (\\x -> ( x, mk 1 )) BD.unsignedInt8) (bs [])', 'BD.decode (BD.float64 BE) (bs [ 1 ])', 'BD.decode (BD.map (\\b -> toList b) (BD.bytes 3)) (bs [ 1 ])',
                   'BD.decode (BD.map2 Tuple.pair (BD.map (\\x -> [ mk x ]) BD.unsignedInt8) (BD.float32 LE)) (bs [ 1, 2 ])'], **bopt)
for kname, d8, ok, short in (("readI8", "BD.signedInt8", "[ 255 ]", "[]"), ("readU8", "BD.unsignedInt8", "[ 255 ]", "[]"),
                             ("readI16", "(BD.signedInt16 BE)", "[ 255, 254 ]", "[ 1 ]"), ("readU16", "(BD.unsignedInt16 LE)", "[ 1, 2 ]", "[ 1 ]"),
                             ("readI32", "(BD.signedInt32 BE)", "[ 128, 0, 0, 1 ]", "[ 1, 2, 3 ]"), ("readU32", "(BD.unsignedInt32 LE)", "[ 255, 255, 255, 255 ]", "[ 1, 2, 3 ]"),
                             ("readF32", "(BD.float32 BE)", "[ 63, 192, 0, 0 ]", "[ 1, 2, 3 ]"), ("readF64", "(BD.float64 LE)", "[ 0, 0, 0, 0, 0, 0, 4, 64 ]", "[ 1, 2, 3, 4, 5, 6, 7 ]")):
    t(BO + kname, ['BD.decode %s (bs %s)' % (d8, ok), 'BD.decode %s (bs %s)' % (d8, short),
                   'let b = bs (%s ++ %s) in ( BD.decode (BD.map2 Tuple.pair %s %s) b, BD.decode (BD.map3 (\\x y z -> [ x, y, z ]) %s %s %s) b, Bytes.width b )' % (ok, ok, d8, d8, d8, d8, d8)], **bopt)
t(BO + "readBytes", ['Maybe.map toList (BD.decode (BD.bytes 2) (bs [ 1, 2, 3 ]))', 'Maybe.map toList (BD.decode (BD.bytes 4) (bs [ 1, 2, 3 ]))',
                     'let b = bs [ 1, 2, 3 ] in ( Maybe.map toList (BD.decode (BD.map2 (\\_ x -> x) BD.unsignedInt8 (BD.bytes 2)) b), toList b )',
                     'Maybe.map toList (BD.decode (BD.bytes 0) (bs []))', 'Maybe.map toList (BD.decode (BD.bytes -1) (bs [ 1 ]))'], needle="fic_bytes_read_bytes", **bopt)
t(BO + "readString", ['BD.decode (BD.string 2) (bs [ 104, 105 ])', 'BD.decode (BD.string 2) (bs [ 195, 40 ])', 'BD.decode (BD.string 3) (bs [ 104, 105 ])',
                      'let b = BE.encode (BE.string (mk 1 ++ "é😣")) in ( BD.decode (BD.string (Bytes.width b)) b, BD.decode (BD.string 3) b, Bytes.width b )',
                      'BD.decode (BD.string 0) (bs [])', 'BD.decode (BD.string -1) (bs [ 1 ])'], needle="fic_bytes_read_string", **bopt)

# ---- elm/regex (runtime/fic_regex.h, overlay/FicOverlayRegex.elm): the nine kernels are reached through the API of Regex; every test has a
# Regex that is shared (used twice), one that is unique, an invalid pattern and a search that finds nothing ----
RGX = "import Regex exposing (Regex)"
RDECL = """
rx : String -> Regex
rx s =
    Regex.fromString s |> Maybe.withDefault Regex.never


fm : Regex.Match -> ( ( String, Int, Int ), List (Maybe String) )
fm m =
    ( ( m.match, m.index, m.number ), m.submatches )
"""
ropt = dict(imports=RGX, decls=RDECL, deps=["elm/regex"])
RO = "author/project:FicOverlayRegex."
t(RO + "compile", ['Regex.contains (rx (mk 1)) (mk 1)', 'let p = mk 2 ++ "+" in ( Regex.contains (rx p) (mk 2 ++ "22"), p )', 'Maybe.map (always ()) (Regex.fromString (mk 3 ++ "("))',
                   'Maybe.map (always ()) (Regex.fromStringWith { caseInsensitive = True, multiline = True } "[a-c]+")', 'Regex.contains Regex.never (mk 4)',
                   'let r = rx "(a|b)*c" in ( ( Regex.contains r "abc", Regex.contains r "ab" ), ( r == r, r == rx "x" ) )',
                   'Maybe.map (always ()) (Regex.fromString "(?<n>a)")', 'Maybe.map (always ()) (Regex.fromString "\\\\p{L}")', 'Maybe.map (always ()) (Regex.fromString "")'],
  needle="fic_re_compile", **ropt)
t(RO + "valid", ['Regex.fromString (mk 1 ++ ")") == Nothing', 'Regex.fromString (mk 1 ++ "[") == Nothing', 'Regex.fromString "a{2,1}" == Nothing',
                 'Maybe.map (always 1) (Regex.fromString "a{2,1")', 'Regex.fromString "*" == Nothing', 'Regex.fromString "x" == Nothing'], needle="fic_re_valid", **ropt)
t(RO + "groups", ['List.map fm (Regex.find (rx "(a)(b)?") (mk 1 ++ "a ab"))', 'List.map (.submatches >> List.length) (Regex.find (rx "((a)(b)(?:c)(d))") "abcd")',
                  'let r = rx "(x)" in ( List.map fm (Regex.find r (mk 2 ++ "x")), List.map fm (Regex.find r "x") )', 'List.map fm (Regex.find (rx "a*") (mk 3))'],
  needle="fic_re_groups", **ropt)
t(RO + "exec", ['List.map fm (Regex.find (rx "[0-9]+") (mk 1 ++ "a22b333"))', 'let s = mk 2 ++ "ab" in ( List.map fm (Regex.find (rx "b") s), s )',
                'List.map fm (Regex.find (rx "(a)|b") "ab")', 'List.map fm (Regex.findAtMost 1 (rx "a") "aaa")', 'List.map fm (Regex.find (rx "q") (mk 4))',
                'List.map fm (Regex.find (rx "😣") "a😣b😣")', 'List.map fm (Regex.find (rx "(?<=a)b") "ab")', 'List.map fm (Regex.find (rx "(a)\\\\1") "aa")',
                'Regex.contains (rx "(a*)*b") (String.repeat 16 "a")'], needle="fic_re_exec", **ropt)
t(RO + "found", ['Regex.contains (rx "a") (mk 1)', 'Regex.contains (rx (mk 1 ++ "x")) (mk 1 ++ "x")', 'Regex.contains (rx "^$") ""', 'Regex.contains (rx "x") ""'],
  needle="fic_re_found", **ropt)
t(RO + "cap", ['List.map fm (Regex.find (rx "(\\\\w)(\\\\d)?") (mk 1))', 'List.map .index (Regex.find (rx "") "a😣b")', 'List.map fm (Regex.find (rx "(a)(?:(b)|c)") "ab ac")'],
  needle="fic_re_cap", **ropt)
t(RO + "slice", ['Regex.replace (rx "[aeiou]") (\\m -> String.toUpper m.match) (mk 1 ++ "education")', 'let s = mk 2 ++ "xaxbx" in ( Regex.replace (rx "[ab]") (\\_ -> "") s, s )',
                 'Regex.replaceAtMost 1 (rx "a") (\\_ -> mk 3) "aaa"', 'Regex.replace (rx "(a)(x)?") (\\m -> String.fromInt m.index ++ String.join "," (List.map (Maybe.withDefault "?") m.submatches)) "a ab"',
                 'Regex.replace (rx "q") (\\_ -> "z") (mk 5)', 'Regex.replace (rx "") (\\_ -> "-") "é😣"', 'Regex.split (rx ",") (mk 1 ++ ",b,,c")', 'Regex.splitAtMost 2 (rx ",") "a,b,c,d"',
                 'Regex.split (rx ",") ""', 'Regex.split (rx "") "é😣a"', 'let s = mk 6 ++ "-x" in ( Regex.split (rx "-") s, s )'], needle="fic_re_slice", **ropt)
t(RO + "size", ['Regex.split (rx "b") (mk 1 ++ "abc")', 'Regex.split (rx "") ""', 'Regex.split (rx "\\\\b") "foo bar"', 'Regex.split (rx "x*") "axb"', 'Regex.split (rx "x") "x"'],
  needle="fic_re_size", **ropt)
t(RO + "advance", ['List.map .index (Regex.find (rx "") (mk 1))', 'List.map .index (Regex.find (rx "") "é😣a")', 'Regex.replace (rx "x*") (\\_ -> "-") "aéb"', 'Regex.split (rx "\\\\b") "é a"'],
  needle="fic_re_advance", **ropt)

# V1 (docs/STAGE4-V1.md): the intrinsics of the flat Vector, each with the three element layouts: RAW (Int, and a record of scalars),
# REF (String) and MAP (a record with references)
V = "elm/core:Vector."
VDECL = '''
type alias P =
    { x : Float, on : Bool, n : Int }


type alias N =
    { name : String, n : Int, tags : List String }


vi : Int -> Vector Int
vi n =
    Vector.fromList (List.range 1 n)


vs : Int -> Vector String
vs n =
    Vector.fromList (List.map mk (List.range 1 n))


vp : Int -> Vector P
vp n =
    Vector.fromList (List.map (\\i -> P (toFloat i / 2) (modBy 2 i == 0) i) (List.range 1 n))


vn : Int -> Vector N
vn n =
    Vector.fromList (List.map (\\i -> N (mk i) i [ mk (i * 10), mk (i * 100) ]) (List.range 1 n))


noV : Vector String
noV =
    Vector.empty


noI : Vector Int
noI =
    Vector.empty


capP : Vector P
capP =
    Vector.withCapacity -5


pushAll : List a -> Vector a -> Vector a
pushAll xs v =
    case xs of
        [] ->
            v

        x :: rest ->
            pushAll rest (Vector.push x v)
'''
vopt = dict(imports="import Vector exposing (Vector)", decls=VDECL)
t(V + "empty", ['Vector.toList noV', 'Vector.length (Vector.push (mk 1) Vector.empty)', 'Vector.toList (Vector.push (N (mk 1) 1 []) Vector.empty)',
                'let e = Vector.empty in ( Vector.toList (Vector.push 1 e), Vector.length e )',
                'Vector.length (Debug.log "e" Vector.empty)', 'Vector.toList (Vector.push (mk 2) (Debug.log "e" noV))'], needle="fic_vector_new(0", **vopt)
t(V + "withCapacity", ['Vector.toList (pushAll [ mk 1, mk 2, mk 3 ] (Vector.withCapacity 2))', 'Vector.toList (pushAll [ 1, 2, 3 ] (Vector.withCapacity 100))',
                       'Vector.length capP', 'let w = Vector.withCapacity 4 in ( Vector.toList (Vector.push (mk 1) w), Vector.toList (Vector.push (mk 2) w) )'],
  needle="fic_vector_new(", **vopt)
t(V + "length", ['Vector.length (vs 5)', 'let a = vn 40 in ( Vector.length a, Vector.get 39 a )', 'Vector.length noI'], needle="FIC_VECTOR_LEN", **vopt)
t(V + "unsafeGet", ['Vector.get 1 (vs 3)', 'let a = vs 50 in ( ( Vector.get 40 a, Vector.get 2 a ), Vector.get 99 a, Vector.length a )', 'Vector.get 0 noV',
                    'Vector.get 2 (vi 3)', '( Vector.get 3 (vi 3), Vector.get -1 (vi 3) )', 'Vector.get 1 (vp 3)', 'let a = vn 3 in ( ( Vector.get 0 a, Vector.get 2 a ), Vector.get 3 a, a )'],
  needle="FIC_VECTOR_GET", **vopt)
# the take is made by the Rc pass from the unsafeGet of Vector.update (elements with references)
t(V + "unsafeTake", ['Vector.toList (Vector.update 1 (\\s -> s ++ "!") (vs 3))', 'let a = vs 3 in ( Vector.toList (Vector.update 0 (\\s -> s ++ "?") a), Vector.toList a )',
                     'Vector.toList (Vector.update 2 (\\r -> { r | name = r.name ++ "+", tags = mk 0 :: r.tags }) (vn 3))',
                     'let a = vn 3 in ( Vector.toList (Vector.update 0 (\\r -> { r | tags = [] }) a), a )',
                     'Vector.toList (Vector.update 7 (\\s -> s ++ "!") (vs 3))', 'Vector.toList (Vector.update -1 (\\r -> { r | n = 0 }) (vn 2))',
                     'Vector.toList (Vector.update 1 (\\n -> n * 10) (vi 3))', 'Vector.toList (Vector.update 1 (\\s -> mk (String.length s)) (vs 2))',
                     'let k = mk 5 in ( Vector.toList (Vector.update 0 (\\_ -> k) (vs 2)), k )'], needle="fic_nil()", **vopt)
t(V + "set", ['Vector.toList (Vector.set 1 (mk 9) (vs 3))', 'let a = vs 3 in ( Vector.toList (Vector.set 0 (mk 8) a), Vector.toList a )',
              'Vector.toList (Vector.set 9 (mk 6) (vs 2))', 'Vector.toList (Vector.set -1 (mk 6) (vs 2))', 'let s = mk 5 in ( Vector.toList (Vector.set 0 s (Vector.set 1 s (vs 2))), s )',
              'Vector.toList (Vector.set 2 77 (vi 4))', 'let a = vi 4 in ( Vector.toList (Vector.set 3 0 a), Vector.toList a, Vector.toList (Vector.set 4 0 a) )',
              'Vector.toList (Vector.set 0 (P 9.5 True 9) (vp 2))', 'let a = vn 3 in ( Vector.toList (Vector.set 1 (N (mk 7) 7 [ mk 8 ]) a), Vector.toList a )',
              'Vector.toList (Vector.set 5 (N (mk 7) 7 [ mk 8 ]) (vn 2))', 'Vector.toList (Vector.set 0 True (Vector.fromList [ False, False ]))'], needle="fic_vector_set", **vopt)
t(V + "swap", ['Vector.toList (Vector.swap 0 2 (vs 3))', 'let a = vs 3 in ( Vector.toList (Vector.swap 0 1 a), Vector.toList a )', 'Vector.toList (Vector.swap 0 3 (vs 3))',
               'Vector.toList (Vector.swap -1 0 (vi 3))', 'Vector.toList (Vector.swap 1 1 (vi 3))', 'Vector.toList (Vector.swap 0 4 (vp 5))',
               'let a = vn 3 in ( Vector.toList (Vector.swap 2 0 a), Vector.toList a )', 'Vector.toList (Vector.swap 1 0 (vn 2))'], needle="fic_vector_swap", **vopt)
# FIX3: `repeat` is a fill loop (RAW, REF and MAP elements; n <= 0), `unsafeSet` and `unsafeSwap` are the overlay's `update` and `filter` (no range test)
t(V + "repeat", ['Vector.toList (Vector.repeat 3 (mk 4))', 'let s = mk 5 in ( Vector.toList (Vector.repeat 4 s), s )', 'Vector.toList (Vector.repeat 0 (mk 6))',
                 'Vector.toList (Vector.repeat -2 (mk 6))', 'Vector.toList (Vector.repeat 70 (N (mk 1) 1 [ mk 2 ]))', 'let r = N (mk 3) 3 [] in ( Vector.length (Vector.repeat 5 r), r )',
                 'Vector.toList (Vector.repeat 5 7)', 'Vector.toList (Vector.repeat 3 (P 1.5 True 2))', 'Vector.toList (Vector.repeat 0 (N (mk 1) 1 []))',
                 'let a = Vector.repeat 3 (mk 9) in ( Vector.toList (Vector.push (mk 1) a), Vector.toList a )', 'Vector.toList (Vector.repeat 200 0)'],
  needle="/* Vector.repeat */", **vopt)
t(V + "unsafeSet", ['Vector.toList (Vector.update 1 (\\s -> s ++ "!") (vs 3))', 'let a = vs 3 in ( Vector.toList (Vector.update 0 (\\s -> s ++ "?") a), Vector.toList a )',
                    'Vector.toList (Vector.update 1 (\\n -> n * 10) (vi 3))', 'Vector.toList (Vector.update 9 (\\n -> n * 10) (vi 3))',
                    'let a = vn 3 in ( Vector.toList (Vector.update 2 (\\r -> { r | n = 0 }) a), a )', 'Vector.toList (Vector.update -1 (\\s -> s) (vs 2))'],
  needle="/* Vector.unsafeSet */", **vopt)
t(V + "unsafeSwap", ['Vector.toList (Vector.filter (\\s -> String.length s > 0) (vs 4))', 'let a = vs 5 in ( Vector.toList (Vector.filter (\\s -> s /= mk 2) a), Vector.toList a )',
                     'Vector.toList (Vector.filter (\\n -> modBy 2 n == 0) (vi 7))', 'Vector.toList (Vector.filter (\\_ -> False) (vs 3))',
                     'let a = vn 4 in ( Vector.toList (Vector.filter (\\r -> r.n > 1) a), a )', 'Vector.toList (Vector.filter (\\p -> p.on) (vp 5))'],
  needle="/* Vector.unsafeSwap */", **vopt)
t(V + "push", ['Vector.toList (Vector.push (mk 9) (vs 2))', 'let a = vs 2 in ( Vector.toList (Vector.push (mk 8) a), Vector.toList a )',
               'Vector.length (pushAll (List.map mk (List.range 1 80)) (vs 1))', 'let s = mk 7 in ( Vector.toList (Vector.push s (Vector.push s Vector.empty)), s )',
               'Vector.toList (pushAll (List.range 1 40) Vector.empty)', 'Vector.toList (Vector.push (P 1.5 False 3) (vp 1))',
               'let a = vn 2 in ( Vector.toList (Vector.push (N (mk 3) 3 []) a), a )', 'Vector.length (pushAll (List.map (\\i -> N (mk i) i [ mk i ]) (List.range 1 70)) Vector.empty)',
               # growth of a unique large vector is realloc (RAW, REF and MAP elements, append): contents, counts and the pointer map survive it
               'Vector.toList (pushAll (List.range 1 3000) Vector.empty)', 'Vector.length (pushAll (List.map (\\i -> N (mk i) i [ mk i ]) (List.range 1 900)) Vector.empty)',
               'Vector.toList (pushAll (List.map mk (List.range 1 700)) Vector.empty)', 'Vector.length (Vector.append (pushAll (List.range 1 40) Vector.empty) (pushAll (List.range 1 3000) Vector.empty))',
               'let a = pushAll (List.range 1 600) Vector.empty in ( Vector.length (Vector.push 0 a), Vector.length a )'],
  needle="fic_vector_push", **vopt)
t(V + "slice", ['Vector.toList (Vector.slice 1 3 (vs 5))', 'let a = vs 5 in ( Vector.toList (Vector.slice -2 5 a), Vector.toList a )', 'Vector.toList (Vector.slice 3 1 (vs 5))',
                'Vector.toList (Vector.slice 0 99 (vi 4))', 'Vector.toList (Vector.slice -99 -1 (vi 4))', 'Vector.toList (Vector.slice 1 2 (vp 3))',
                'let a = vn 4 in ( Vector.toList (Vector.slice 1 3 a), Vector.length a )', 'Vector.toList (Vector.slice 0 0 (vn 2))'], needle="fic_vector_slice", **vopt)
t(V + "append", ['Vector.toList (Vector.append (vs 2) (vs 3))', 'let a = vs 2 in ( Vector.toList (Vector.append a a), Vector.toList a )',
                 'let a = vs 2 in let b = vs 1 in ( Vector.toList (Vector.append a b), Vector.toList (Vector.append b a), Vector.toList a )',
                 'Vector.toList (Vector.append Vector.empty (vs 2))', 'Vector.toList (Vector.append (vs 2) Vector.empty)', 'Vector.toList (Vector.append (vi 3) (vi 2))',
                 'Vector.toList (Vector.append (pushAll [ 1, 2 ] (Vector.withCapacity 10)) (vi 3))', 'Vector.toList (Vector.append (vp 1) (vp 2))',
                 'let a = vn 2 in ( Vector.toList (Vector.append (vn 1) a), Vector.toList (Vector.append a (vn 1)), a )'], needle="fic_vector_append", **vopt)
t(V + "fromList", ['Vector.toList (Vector.fromList [ mk 1, mk 2 ])', 'let l = List.map mk (List.range 1 70) in ( Vector.length (Vector.fromList l), List.length l )',
                   'Vector.toList (Vector.fromList noS)', 'Vector.fromList [ 1, 2, 3 ]', 'Vector.fromList [ \'a\', \'b\' ]', 'Vector.fromList [ 1.5, -0.25 ]',
                   'Vector.fromList [ ( 1, mk 2 ), ( 3, mk 4 ) ]', 'let l = [ N (mk 1) 1 [ mk 2 ] ] in ( Vector.fromList l, l )', 'Vector.fromList [ vs 1, vs 2, Vector.empty ]',
                   'Vector.fromList [ [ mk 1 ], [] ]', 'Vector.fromList [ Just (mk 1), Nothing ]', 'Vector.fromList [ (), () ]'], needle="fic_vfl_", **vopt)
t(V + "toList", ['Vector.toList (vs 3)', 'let a = vs 3 in ( Vector.toList a, Vector.toList a, a )', 'Vector.toList noV', 'Vector.toList (vi 3)',
                 'Vector.toList (vp 2)', 'let a = vn 2 in ( Vector.toList a, a )', 'List.map Vector.toList (Vector.toList (Vector.fromList [ vi 1, vi 2 ]))',
                 'vn 2 == vn 2', 'vs 2 == vs 3', 'vp 3 == Vector.set 1 (P 0 False 0) (vp 3)', 'Vector.fromList [ vi 1, vi 2 ] == Vector.fromList [ vi 1, vi 2 ]'], needle="fic_vtl_", **vopt)

ELM_JSON = '''{"type": "application", "source-directories": ["src"], "elm-version": "0.19.3",
 "dependencies": {"direct": {"elm/core": "1.0.5"%s}, "indirect": {%s}}, "test-dependencies": {"direct": {}, "indirect": {}}}
'''
CFLAGS = ["-std=c99", "-ffp-contract=off", "-w"]
SAN = ["-O1", "-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-g", "-DFIC_NO_POOL", "-DFIC_STATS"]


def needed():
    """the kernels of the table that hold a reference: a `b` or `o` in the signature, or a reference result"""
    ar, sig = kernel_sigs.table()
    ref_result = {"elm/core:String.fromInt", "elm/core:String.fromFloat", "elm/core:Elm.JsArray.empty", "elm/core:Platform.Cmd.none", "elm/core:Platform.Sub.none",
                  "elm/json:Json.Encode.int", "elm/json:Json.Encode.float", "elm/json:Json.Encode.bool", "elm/json:Json.Encode.null", "elm/json:Json.Decode.string",
                  "elm/json:Json.Decode.bool", "elm/json:Json.Decode.int", "elm/json:Json.Decode.float", "elm/json:Json.Decode.value",
                  "author/project:FicOverlayJson.objectKeys", "author/project:FicOverlayBytes.failure",
                  "elm/core:Vector.empty", "elm/core:Vector.withCapacity"}
    out = []
    for c in ar:
        s = "bb" if c == "elm/core:Basics.append" else sig.get(c, "")
        if "b" in s or "o" in s or c in ref_result: out.append(c)
    return out + ["elm/core:Basics.append/list", "parser string cache", "elm/core:Debug.todo/crash"]


def program(kernel):
    exprs, opt = T[kernel]
    lets = ""
    for i, e in enumerate(exprs):
        lets += "                    o%d =\n                        Debug.log \"o%d\" (Debug.toString (%s))\n\n" % (i, i, e)
    return HEAD % (opt.get("imports", ""), opt.get("decls", ""), lets, " ++ ".join("o%d" % i for i in range(len(exprs))))


def sh(cmd, cwd=None, env=None):
    try:
        p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, timeout=300)
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"


def run_one(a, kernel, work):
    exprs, opt = T[kernel]
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(os.path.join(work, "src"))
    deps = opt.get("deps", []) + (["elm/parser"] if opt.get("parser") else [])
    versions = {"elm/parser": "1.1.0", "elm/json": "1.1.3", "elm/bytes": "1.0.8", "elm/regex": "1.0.0"}
    open(os.path.join(work, "elm.json"), "w").write(ELM_JSON % ("".join(', "%s": "%s"' % (d, versions[d]) for d in deps), "" if "elm/json" in deps else '"elm/json": "1.1.3"'))
    open(os.path.join(work, "src", "Main.fic"), "w").write(program(kernel))
    env = dict(os.environ, ELM_HOME=a.elm_home)
    elm = os.path.abspath(a.elm)
    crash = opt.get("crash")
    rc, so, se = sh([a.safe, elm, "make", "src/Main.fic", "--output=norc.c", "--no-rc"], cwd=work, env=env)
    if rc != 0: return "the --no-rc compile failed: " + (so + se)[-500:]
    rc, so, se = sh(["gcc"] + CFLAGS + ["-O1", "norc.c", "-o", "norc", "-lm"], cwd=work)
    if rc != 0: return "the --no-rc C build failed: " + se[-300:]
    rc0, oracle, se0 = sh([a.safe, "./norc"], cwd=work)
    if (rc0 != 0) != bool(crash): return "the --no-rc program: exit %d %s" % (rc0, se0[-300:])
    rc, so, se = sh([a.safe, elm, "make", "src/Main.fic", "--output=rc.c", "--rc"], cwd=work, env=env)
    if rc != 0: return "the --rc compile failed: " + (so + se)[-500:]
    text = open(os.path.join(work, "rc.c"), encoding="utf-8", errors="replace").read()
    gen = text[text.find("/* generated by the Ficus compiler"):]
    if opt.get("needle") and opt["needle"] not in gen: return "the generated C does not call %s: the test does not reach the kernel" % opt["needle"]
    rc, so, se = sh(["gcc"] + CFLAGS + SAN + ["rc.c", "-o", "rc", "-lm"], cwd=work)
    if rc != 0: return "the --rc C build failed: " + se[-300:]
    rc, got, se = sh([a.safe, "./rc"], cwd=work, env=dict(os.environ, ASAN_OPTIONS="detect_leaks=%d" % (0 if crash else 1)))
    if crash:        # a run time error ends the program: exit status and message as in the oracle, memory errors still reported, no leak check
        if rc != rc0 or crash not in se or "AddressSanitizer" in se or "runtime error" in se: return "crash test: exit %d (oracle %d): %s" % (rc, rc0, se[-400:])
        return None
    if rc != 0: return "exit %d: %s" % (rc, se[-600:])
    if got != oracle: return "output differs from the --no-rc build"
    if " live 0 " not in se: return "not 0 live objects: " + se[-200:]
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm"); ap.add_argument("--elm-home"); ap.add_argument("--safe"); ap.add_argument("--only", default="")
    ap.add_argument("--out", default=None); ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    need = needed()
    missing = [k for k in need if k not in T]
    extra = [k for k in T if k not in need]
    if a.list:
        for k in need: print("%-48s %s" % (k, "%d calls" % len(T[k][0]) if k in T else "NO TEST"))
        return 1 if missing else 0
    only = [x for x in a.only.split(",") if x]
    a.safe = os.path.abspath(a.safe)
    work = a.out or tempfile.mkdtemp(prefix="kerneltests")
    bad = len(missing)
    for k in missing: print("FAIL %s: no test for this kernel" % k)
    for k in extra: print("note: %s is tested but is not a kernel with a reference in the table" % k)
    n = 0
    for k in need:
        if k not in T or (only and not any(o in k for o in only)): continue
        why = run_one(a, k, os.path.join(work, "k"))
        n += 1
        if why: bad += 1; print("FAIL %s: %s" % (k, why.replace("\n", " | ")[:900]), flush=True)
        else: print("ok   %s (%d calls)" % (k, len(T[k][0])), flush=True)
    print("kernel tests: %d kernels tested, %d failed, %d without a test" % (n, bad - len(missing), len(missing)))
    if not a.out: shutil.rmtree(work, ignore_errors=True)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
