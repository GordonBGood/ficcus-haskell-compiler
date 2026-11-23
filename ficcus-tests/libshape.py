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
