"""H16 W3 fix: the shape that the first gates of the Known pass missed, for rcfuzz.py and v2fuzz.py: a library function that takes a function
(Dict.filter, Dict.partition, List.foldl, List.map, Array.initialize) called inside the four places of a worker (`init`, `update`,
`subscriptions` and a `view` helper), with a lambda that captures a local and one that does not. The module that uses it needs
`import Array` and `import Dict`. shapes(r) returns (definitions, names): the definitions of shpView, shpUpdate, shpSubs, shpInit (all
`Int -> Int`) and their names. The generator draws from its own random generator `r`, so the programs of the fuzzers do not change."""


def _lam2(r, cap, a, b):
    ops = ["+", "-", "*"]
    c = r.randint(1, 4)
    e = "%s %s %d" % (a, r.choice(ops), c)
    if cap: e = "(%s) %s k" % (e, r.choice(ops))
    return "%s %s %s" % (e, r.choice([">", "<", ">=", "/="]), r.randint(0, 25))


def _one(r, fn, cap):
    c = r.randint(1, 5)
    kk = " + k" if cap else ""
    if fn == "filter":
        return ("Dict.foldl (\\_ v a -> a + v) 0 (Dict.filter (\\key v -> %s) (Dict.fromList [ ( 1, 10 ), ( 2, 20 ), ( 3, 30 ), ( 4, 40 ) ]))"
                % _lam2(r, cap, "key * v", "key"))
    if fn == "partition":
        return ("(\\( p, q ) -> Dict.size p * 10 + Dict.size q) (Dict.partition (\\key v -> %s) (Dict.fromList [ ( 1, 10 ), ( 2, 20 ), ( 3, 30 ), ( 4, 40 ) ]))" % _lam2(r, cap, "key + v", "key"))
    if fn == "foldl":
        return "List.foldl (\\x acc -> acc + x * %d%s) 0 [ 1, 2, 3, 4, 5 ]" % (c, kk)
    if fn == "map":
        return "List.sum (List.map (\\x -> x * %d%s) [ 1, 2, 3 ])" % (c, kk)
    return "Array.foldl (+) 0 (Array.initialize 5 (\\i -> i * %d%s))" % (c, kk)


def shapes(r):
    fns = ["filter", "partition", "foldl", "map", "initialize"]
    out, names = [], []
    for name in ("shpView", "shpUpdate", "shpSubs", "shpInit"):
        a, b = r.choice(fns), r.choice(fns)
        out.append("\n\n%s : Int -> Int\n%s k =\n    let\n        n1 =\n            %s\n\n        n2 =\n            %s\n\n        n3 =\n            %s\n    in\n    n1 + n2 * 2 + n3 * 3 + k\n"
                   % (name, name, _one(r, a, False), _one(r, b, True), _one(r, r.choice(fns), r.random() < 0.5)))
        names.append(name)
    return "".join(out), names


# H16 W5 (rule 1a): a parser combinator library whose specialized copies are lifted lambdas: copies that capture nothing (inlined into callers),
# a copy with captures (`k`), a recursive copy (`shpMany`'s local loop). Derived from ficus-tests/known10. `shpParse : Int -> Int`.
_PARSER_LIB = r"""

type alias ShpState =
    { src : List Int, pos : Int }


type ShpStep a
    = ShpGood Bool a ShpState
    | ShpBad Bool String


type alias ShpParser a =
    ShpState -> ShpStep a


shpSym : Int -> ShpParser ()
shpSym c =
    \s ->
        case s.src of
            h :: t ->
                if h == c then
                    ShpGood True () { src = t, pos = s.pos + 1 }

                else
                    ShpBad False "symbol"

            [] ->
                ShpBad False "eof"


shpDigit : ShpParser Int
shpDigit =
    \s ->
        case s.src of
            h :: t ->
                if h >= 48 && h <= 57 then
                    ShpGood True (h - 48) { src = t, pos = s.pos + 1 }

                else
                    ShpBad False "digit"

            [] ->
                ShpBad False "eof"


shpMap : (a -> b) -> ShpParser a -> ShpParser b
shpMap f p =
    \s ->
        case p s of
            ShpGood c a s1 ->
                ShpGood c (f a) s1

            ShpBad c m ->
                ShpBad c m


shpMap2 : (a -> b -> c) -> ShpParser a -> ShpParser b -> ShpParser c
shpMap2 f pa pb =
    \s ->
        case pa s of
            ShpBad c m ->
                ShpBad c m

            ShpGood c1 a s1 ->
                case pb s1 of
                    ShpBad c2 m ->
                        ShpBad (c1 || c2) m

                    ShpGood c2 b s2 ->
                        ShpGood (c1 || c2) (f a b) s2


shpOr : ShpParser a -> ShpParser a -> ShpParser a
shpOr pa pb =
    \s ->
        case pa s of
            ShpGood c a s1 ->
                ShpGood c a s1

            ShpBad c1 m1 ->
                if c1 then
                    ShpBad c1 m1

                else
                    case pb s of
                        ShpGood c a s1 ->
                            ShpGood c a s1

                        ShpBad c2 m2 ->
                            ShpBad c2 m2


shpMany : ShpParser a -> ShpParser (List a)
shpMany p =
    \s ->
        let
            go acc st =
                case p st of
                    ShpGood _ a s1 ->
                        go (a :: acc) s1

                    ShpBad c m ->
                        if c then
                            ShpBad c m

                        else
                            ShpGood (not (List.isEmpty acc)) (List.reverse acc) st
        in
        go [] s


shpOneOf : List (ShpParser a) -> ShpParser a
shpOneOf ps =
    \s -> shpOneOfHelp s ps


shpOneOfHelp : ShpState -> List (ShpParser a) -> ShpStep a
shpOneOfHelp s ps =
    case ps of
        [] ->
            ShpBad False "oneOf"

        p :: rest ->
            case p s of
                ShpGood c a s1 ->
                    ShpGood c a s1

                ShpBad c m ->
                    if c then
                        ShpBad c m

                    else
                        shpOneOfHelp s rest


shpLazy : (() -> ShpParser a) -> ShpParser a
shpLazy thunk =
    \s -> thunk () s


shpNest : ShpParser Int
shpNest =
    shpLazy (\_ -> shpOneOf [ shpMap2 (\_ d -> d + 1) (shpSym 40) (shpMap2 (\d _ -> d) shpNest (shpSym 41)), shpMap (\_ -> 0) (shpSym 46) ])


shpNum : ShpParser Int
shpNum =
    shpMap (List.foldl (\d acc -> acc * 10 + d) 0) (shpMany shpDigit)


shpRes : ShpStep Int -> Int
shpRes r =
    case r of
        ShpGood c a s ->
            (if c then 1000 else 0) + a * 7 + s.pos

        ShpBad c _ ->
            if c then 99 else 98
"""


def shp_alt(r, c1, c2):
    """One alternative of a static `oneOf` list."""
    return r.choice(["shpNum", "shpMap (\\_ -> %d) (shpSym %d)" % (r.randint(0, 9), ord(r.choice(",;:"))), "shpMap2 (\\_ n -> n + 1) (shpSym %d) shpNum" % ord(c1),
                     "shpMap (\\_ -> 7) (shpMap2 (\\_ n -> n) (shpSym %d) (shpSym %d))" % (ord(c1), ord(c2)), "shpDigit"])


def parser_shape(r):
    """The definitions of `shpParse : Int -> Int`, drawn from `r` after the draws of shapes() (those do not change)."""
    c1, c2 = r.choice(",;:"), r.choice(",;:")
    forms = [
        "shpNum",
        "shpOr (shpMap2 (\\_ n -> n) (shpSym %d) shpNum) shpNum" % ord(c1),
        "shpMap2 (\\a b -> a * 3 + b) shpNum (shpMap2 (\\_ n -> n) (shpSym %d) shpNum)" % ord(c2),
        "shpMap2 (\\_ n -> n) (shpSym (k + 44)) shpNum",                           # a copy with captures: the parser depends on k
        "shpMap (\\n -> n * k + 1) (shpMap2 (\\n _ -> n) shpNum (shpSym %d))" % ord(c1),
        "shpMap List.length (shpMany (shpMap2 (\\n _ -> n) shpDigit (shpSym %d)))" % ord(c2),   # a recursive copy
        "shpMap List.sum (shpMany (shpMap2 (\\_ n -> n) (shpSym %d) shpNum))" % ord(c1),
    ]
    terms = []
    for _ in range(3):
        text = "".join(r.choice("0123456789,;:") for _ in range(r.randint(3, 10)))
        terms.append("shpRes ((%s) { src = List.map Char.toCode (String.toList \"%s\"), pos = 0 })" % (r.choice(forms), text))
    # H16 W6 (rule 1b): `oneOf` over static lists of 1 to 8 parsers (the spine rule fires), a recursive grammar, and the cases where it must not fire
    # (a parser that captures `k`, a list used as a value). Drawn after the draws above.
    sp = [shp_alt(r, c1, c2) for _ in range(r.randint(1, 8))]
    sp_forms = [
        "shpOneOf [ %s ]" % ", ".join(sp),
        "shpOneOf [ %s, shpNum ]" % sp[0],
        "shpMap2 (\\a b -> a * 5 + b) (shpOneOf [ %s ]) (shpOneOf [ shpNum, %s ])" % (", ".join(sp[:3]), sp[-1]),
        "shpMap2 (\\a b -> a + b) shpNest shpNest",
        "shpOneOf [ shpMap (\\_ -> k) (shpSym 59), shpMap (\\_ -> k + 1) (shpSym (k + 44)), shpNum ]",           # a parser that captures k: no spine
        "(let ps = [ %s ] in shpMap (\\n -> n + List.length ps) (shpOneOf ps))" % ", ".join(sp[:2]),         # the list is also a value
    ]
    for _ in range(3):
        text = "".join(r.choice("0123456789,;:().") for _ in range(r.randint(2, 9)))
        terms.append("shpRes ((%s) { src = List.map Char.toCode (String.toList \"%s\"), pos = 0 })" % (r.choice(sp_forms), text))
    return _PARSER_LIB + "\n\nshpParse : Int -> Int\nshpParse k =\n    " + "\n        + ".join(terms) + "\n"


# H16 W7a (rule 2, unboxed results of Known clones): a library whose combinators have known function arguments and a four constructor result type
# with mixed leaf classes (S9: slots shared across constructors, each branch leaves different slots dead), identity after unpack (S10: the same
# constructor again, another result type, owned and borrowed), a state with a Vector (V1 to V5: the vector is updated after the match, shared,
# in a loop, next to the slot of `UBad`'s message, read then updated), producers with a local loop (not put in place of their calls), a self tail
# loop, a non tail recursion. The module needs `import Vector exposing (Vector)`. `ubxRun : Int -> Int`.
_UBX_LIB = r"""

type alias UState =
    { src : List Int, pos : Int, vec : Vector Int }


type UQ a
    = UOne Int String UState
    | UTwo Float
    | UThree ( Int, Int ) Bool a
    | UFour String String
    | UGood Bool a UState


type alias UP a =
    UState -> UQ a


ubxItem : UP Int
ubxItem =
    \s ->
        case s.src of
            h :: t ->
                if h < 10 then
                    UOne h (String.fromInt h) { s | src = t, pos = s.pos + 1 }

                else if h < 20 then
                    UTwo (toFloat h / 3)

                else if h < 30 then
                    UThree ( h, s.pos ) (modBy 2 h == 0) h

                else if h < 40 then
                    UGood (h > 35) h { s | src = t, pos = s.pos + 1, vec = Vector.set (modBy 4 h) h s.vec }

                else
                    UFour (String.fromInt h) "big"

            [] ->
                UFour "eof" "end"


ubxBump : (Int -> Int) -> UP Int
ubxBump f =
    \s ->
        let
            go i =
                case Vector.get i s.vec of
                    Just v ->
                        if modBy 3 v == 0 && i < 3 then
                            go (i + 1)

                        else
                            UGood True v { s | vec = Vector.set i (f v) s.vec, pos = s.pos + i }

                    Nothing ->
                        UFour "end" "vec"
        in
        go (modBy 4 s.pos)


ubxRemap : (Int -> Int) -> UP Int -> UP Int
ubxRemap f p =
    \s ->
        case p s of
            UOne n m st ->
                if n > 3 then
                    UOne n m st

                else
                    UOne (f n) (m ++ "!") st

            UTwo x ->
                UTwo x

            UThree ( a, b ) flag v ->
                if flag then
                    UThree ( b, a ) flag (f v)

                else
                    UTwo (toFloat a)

            UFour c m ->
                if String.length c > 2 then
                    UFour c m

                else
                    UFour m c

            UGood c a st ->
                UGood (not c) (f a) st


ubxToStr : (Int -> String) -> UP Int -> UP String
ubxToStr f p =
    \s ->
        case p s of
            UOne n m st ->
                UOne n m st

            UTwo x ->
                UTwo x

            UThree ab flag v ->
                UThree ab flag (f v)

            UFour c m ->
                UFour c m

            UGood c a st ->
                UGood c (f a) st


ubxChain : UP Int -> UP Int -> UP Int
ubxChain p1 p2 =
    \s ->
        case p1 s of
            UGood c n st ->
                case p2 st of
                    UGood c2 k st2 ->
                        UGood (c || c2) (n + k) { st2 | vec = Vector.update 0 (\x -> x + k) st2.vec }

                    other ->
                        other

            other ->
                other


ubxOneOf : List (UP a) -> UP a
ubxOneOf ps =
    \s -> ubxOneOfHelp s ps


ubxOneOfHelp : UState -> List (UP a) -> UQ a
ubxOneOfHelp s ps =
    case ps of
        [] ->
            UFour "oneOf" "none"

        p :: rest ->
            case p s of
                UGood c a s1 ->
                    UGood c a s1

                UFour _ _ ->
                    ubxOneOfHelp s rest

                other ->
                    other


ubxLoop : Int -> UP Int -> UP Int
ubxLoop n p =
    \s ->
        let
            go i acc st =
                if i <= 0 then
                    UGood (acc > 3) acc st

                else
                    case p st of
                        UGood _ a st1 ->
                            go (i - 1) (acc + a) { st1 | vec = Vector.update (modBy 4 i) (\x -> x + a) st1.vec }

                        UFour c m ->
                            UFour c m

                        other ->
                            other
        in
        go n 0 s


ubxTimes : Int -> UP Int -> UP Int
ubxTimes n p =
    \s ->
        if n <= 0 then
            UGood False 0 s

        else
            case ubxTimes (n - 1) p s of
                UGood c1 a s1 ->
                    case p s1 of
                        UGood c2 b s2 ->
                            UGood (c1 || c2) (a + b) s2

                        other ->
                            other

                other ->
                    other


ubxStart : List Int -> UState
ubxStart xs =
    { src = xs, pos = 0, vec = Vector.fromList [ 1, 2, 3, 4 ] }


ubxSum : Vector Int -> Int
ubxSum v =
    Vector.foldl (\x acc -> acc * 3 + x) 0 v


ubxRes : UQ Int -> Int
ubxRes q =
    case q of
        UOne n m st ->
            n * 3 + String.length m + st.pos + ubxSum st.vec

        UTwo x ->
            truncate (x * 10)

        UThree ( a, b ) flag v ->
            a + b * 7 + v + (if flag then 100 else 0)

        UFour c m ->
            String.length c * 11 + String.length m

        UGood c a st ->
            a * 5 + st.pos + ubxSum (Vector.set 1 77 st.vec) + (if c then 1000 else 0)


-- the V shapes: the result is matched and the vector of the state is updated (V1), the caller keeps the state and reads it after (V2), the vector
-- shares a slot with the message of UFour (V4), the vector is read, then updated (V5)
ubxV : Int -> UP Int -> List Int -> Int
ubxV shape p xs =
    let
        s =
            ubxStart xs
    in
    case shape of
        0 ->
            case p s of
                UGood _ a st ->
                    a + ubxSum (Vector.update 2 (\x -> x * 2) st.vec)

                other ->
                    ubxRes other

        1 ->
            case p s of
                UGood _ a st ->
                    a + ubxSum (Vector.set 3 9 st.vec) + ubxSum s.vec

                other ->
                    ubxRes other

        2 ->
            case p s of
                UFour c m ->
                    String.length c + String.length m

                UGood _ a st ->
                    a + ubxSum (Vector.push 5 st.vec)

                other ->
                    ubxRes other

        _ ->
            case p s of
                UGood _ a st ->
                    let
                        first =
                            Maybe.withDefault -1 (Vector.get 0 st.vec)
                    in
                    a + first + ubxSum (Vector.set 0 (first * 2) st.vec)

                other ->
                    ubxRes other
"""


def unbox_shape(r):
    """The definitions of `ubxRun : Int -> Int` (and the library above), drawn from `r` after every other draw of the generator."""
    def lam():
        return r.choice(["\\n -> n + %d" % r.randint(1, 9), "\\n -> n * %d" % r.randint(2, 4), "\\n -> n - %d" % r.randint(1, 3), "identity"])
    prods = [
        "ubxItem",
        "ubxRemap (%s) ubxItem" % lam(),
        "ubxRemap (%s) (ubxRemap (%s) ubxItem)" % (lam(), lam()),
        "ubxBump (%s)" % lam(),
        "ubxChain ubxItem ubxItem",
        "ubxChain (ubxBump (%s)) (ubxRemap (%s) ubxItem)" % (lam(), lam()),
        "ubxOneOf [ ubxBump (%s), ubxItem ]" % lam(),
        "ubxOneOf [ ubxRemap (%s) ubxItem, ubxBump (%s), ubxItem ]" % (lam(), lam()),
        "ubxLoop %d ubxItem" % r.randint(1, 4),
        "ubxLoop %d (ubxBump (%s))" % (r.randint(1, 5), lam()),
        "ubxTimes %d (ubxRemap (%s) ubxItem)" % (r.randint(1, 4), lam()),
        "ubxTimes %d (ubxBump (%s))" % (r.randint(1, 3), lam()),
    ]
    terms = []
    for _ in range(r.randint(4, 7)):
        xs = "[ %s ]" % ", ".join(str(r.choice([1, 2, 3, 5, 9, 12, 15, 21, 24, 31, 36, 38, 45, 50])) for _ in range(r.randint(0, 6)))
        p = r.choice(prods)
        kind = r.randint(0, 6)
        if kind <= 2:
            terms.append("ubxRes ((%s) (ubxStart %s))" % (p, xs))
        elif kind == 3:
            terms.append("(let rr = (%s) (ubxStart %s) in ubxRes rr + List.length [ rr, rr ])" % (p, xs))        # stored: the wrapper
        elif kind == 4:
            terms.append("List.sum (List.map (\\f -> ubxRes (f (ubxStart %s))) [ %s, ubxItem ])" % (xs, p))     # a closure entry
        elif kind == 5:
            terms.append("ubxV %d (%s) %s" % (r.randint(0, 3), p, xs))
        else:
            terms.append("(case ubxToStr String.fromInt (%s) (ubxStart %s) of\n            UGood _ a st -> String.length a + st.pos\n            UFour c m -> String.length c + String.length m\n            _ -> 7)" % (p, xs))
    return _UBX_LIB + "\n\nubxRun : Int -> Int\nubxRun k =\n    k + " + "\n        + ".join(terms) + "\n"
