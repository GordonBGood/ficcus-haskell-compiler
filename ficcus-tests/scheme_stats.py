#!/usr/bin/env python3
"""Exact clone counts from the schemes-as-data of the typed dump (stage (ii) step 7, item 2).

Runs the typed corpus check (same arguments as typed_check.py) and reads every .types file it writes.
  def lines:  id: <def id>   sig: <scheme with v0, v1.. >   kinds: v0:comparable,v1:row,...
  use lines:  callee: <def id>   sig#: <hash of the callee scheme>   subst: v0 := T, ...
A variable of an enclosing definition appears as <<ownerId|vN>>.

Marks: a variable is marked when its kind is number / comparable / appendable / compappend, or when it
is the operand type of == or /= (equatable), directly (Basics.eq / Basics.neq, v0) or by being passed to a
marked variable of a callee (propagated to the owner of every variable in the instance type; fixpoint).
Clones of a callee = distinct instances of its marked variables, found at uses whose types are concrete
and, transitively, inside the clones that use the marked variables of their owner (closure).
"""
import sys, re, json, os, collections, threading
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import typed_check as tc

LOCK = threading.Lock()
DEFS = {}                      # id -> (kinds {vN: kind}, sig hash)
USES = set()                   # (callee, sighash, ((vN, type text), ...))
TOKEN = re.compile(r"<<([^|>]*)\|(v\d+)>>")
CONSTRAINED = ("number", "comparable", "appendable", "compappend")
ROOTS = {("elm/core:Basics.eq", "v0"), ("elm/core:Basics.neq", "v0")}


def sig_hash(text):
    h = 5381
    for c in text:
        h = (h * 33 + ord(c)) % 4294967291
    return "%08x" % h


def split_top(s):
    out, d, cur, i = [], 0, "", 0
    while i < len(s):
        ch = s[i]
        if ch in "({[": d += 1
        if ch in ")}]": d -= 1
        if ch == "," and d == 0 and s[i + 1:i + 2] == " ":
            out.append(cur); cur = ""; i += 2; continue
        cur += ch; i += 1
    out.append(cur)
    return out


LINE_DEF = re.compile(r"^\s*def \S+ :: .*?   id: (\S+)   sig: (.*?)   kinds: (.*)$")
LINE_CTOR = re.compile(r"^  ctor \S+   id: (\S+)   tag: \d+   arity: \d+   fields: .*?   sig: (.*?)   kinds: (.*)$")
LINE_USE = re.compile(r"   callee: (\S+)(?:   use: \w+)?(?:   instance: .*?)?   sig#: (\w+)   subst: (.*)$")


def parse(path):
    defs, uses = {}, set()
    for line in open(path, encoding="utf-8"):
        if line.startswith("  ctor "):
            m = LINE_CTOR.match(line.rstrip("\n"))
            if m:
                kinds = dict(k.split(":", 1) for k in m.group(3).split(",") if k)
                defs[m.group(1)] = (kinds, sig_hash(m.group(2)))
            continue
        if "def " in line[:200] and "   kinds: " in line:
            m = LINE_DEF.match(line.rstrip("\n"))
            if m:
                kinds = dict(k.split(":", 1) for k in m.group(3).split(",") if k)
                defs[m.group(1)] = (kinds, sig_hash(m.group(2)))
            continue
        i = line.find("   sig#: ")
        if i < 0: continue
        m = LINE_USE.search(line.rstrip("\n"))
        if not m: continue
        binds = []
        for b in split_top(m.group(3)):
            if " := " in b:
                v, t = b.split(" := ", 1)
                binds.append((v.strip(), t.strip().removesuffix(" (defaulted)")))
        if binds:
            uses.add((m.group(1), m.group(2), tuple(binds)))
    return defs, uses


LOCAL_MISMATCH = set()         # (callee, use hash, def hash) inside one dump (one version of every package)
UNKNOWN = collections.Counter()
UNKNOWN_OTHER = collections.Counter()


def classify(callee):
    if callee.startswith("elm/core:Debug."): return "debug"
    last = callee.rsplit(":", 1)[-1].split("@")[0].rsplit(".", 1)[-1]
    if last[:1].isupper(): return "constructor"
    if last and not (last[0].isalpha() or last[0] == "_"): return "operator"
    return "other"


def count(path):
    d, u = parse(path)
    lm, un, uo = set(), collections.Counter(), collections.Counter()
    for c, h, _ in u:
        if c in d:
            if d[c][1] != h: lm.add((c, h, d[c][1]))
        else:
            k = classify(c); un[k] += 1
            if k == "other": uo[c] += 1
    with LOCK:
        DEFS.update(d); USES.update(u); LOCAL_MISMATCH.update(lm); UNKNOWN.update(un); UNKNOWN_OTHER.update(uo)


# ---- type text -> tree
TOK = re.compile(r"\s*(<<[^>]*>>|ref\([a-z]+\)|->|[(){}|,:]|[A-Za-z_][A-Za-z0-9_.#]*)")


def tokenize(s):
    pos, out = 0, []
    while pos < len(s):
        m = TOK.match(s, pos)
        if not m: break
        out.append(m.group(1)); pos = m.end()
    return out


def parse_type(s):
    toks = tokenize(s); pos = [0]

    def peek(): return toks[pos[0]] if pos[0] < len(toks) else None
    def nxt(): t = toks[pos[0]]; pos[0] += 1; return t

    def fun():
        a = app()
        if peek() == "->":
            nxt(); return ("->", a, fun())
        return a

    def app():
        t = peek()
        if t and t[0].isupper():
            nxt(); args = []
            while peek() is not None and (peek()[0].isalpha() or peek() in ("(", "{") or peek().startswith("<<") or peek().startswith("ref(")):
                args.append(atom())
            return ("T", t, tuple(args))
        return atom()

    def atom():
        t = nxt()
        if t == "(":
            if peek() == ")":
                nxt(); return ("unit",)
            first = fun(); items = [first]
            while peek() == ",":
                nxt(); items.append(fun())
            nxt()
            return first if len(items) == 1 else ("tuple",) + tuple(items)
        if t == "{":
            ext = None; fields = []
            if peek() == "}":
                nxt(); return ("rec", None, ())
            if len(toks) > pos[0] + 1 and toks[pos[0] + 1] == "|":
                ext = nxt(); nxt()
            while True:
                name = nxt(); nxt(); fields.append((name, fun()))
                if peek() == ",": nxt(); continue
                break
            nxt()
            return ("rec", ext, tuple(fields))
        if t[0].isupper():
            return ("T", t, ())
        return t                     # variable, token, ref(...)
    return fun()


def show(t):
    if isinstance(t, str): return t
    k = t[0]
    if k == "->": return "(%s -> %s)" % (show(t[1]), show(t[2]))
    if k == "T": return t[1] if not t[2] else "(%s %s)" % (t[1], " ".join(show(a) for a in t[2]))
    if k == "unit": return "()"
    if k == "tuple": return "(" + ", ".join(show(a) for a in t[1:]) + ")"
    if k == "rec": return "{" + (show(t[1]) + " | " if t[1] else "") + ", ".join(n + ":" + show(x) for n, x in t[2]) + "}"
    return str(t)


def tokens_of(t, acc):
    if isinstance(t, str):
        if t.startswith("<<"): acc.add(t)
        return
    k = t[0]
    if k == "->": tokens_of(t[1], acc); tokens_of(t[2], acc)
    elif k == "T":
        for a in t[2]: tokens_of(a, acc)
    elif k == "tuple":
        for a in t[1:]: tokens_of(a, acc)
    elif k == "rec":
        if t[1]: tokens_of(t[1], acc)
        for _, x in t[2]: tokens_of(x, acc)


def subst(t, env):
    if isinstance(t, str): return env.get(t, t)
    k = t[0]
    if k == "->": return ("->", subst(t[1], env), subst(t[2], env))
    if k == "T": return ("T", t[1], tuple(subst(a, env) for a in t[2]))
    if k == "tuple": return ("tuple",) + tuple(subst(a, env) for a in t[1:])
    if k == "rec":
        ext = t[1]
        if ext and ext in env:       # a row variable bound to a record: merge fields
            e = env[ext]
            if isinstance(e, tuple) and e[0] == "rec":
                return ("rec", e[1], tuple(sorted(e[2] + tuple((n, subst(x, env)) for n, x in t[2]))))
        return ("rec", ext, tuple((n, subst(x, env)) for n, x in t[2]))
    return t


def tok_split(tok):
    m = TOKEN.fullmatch(tok)
    return m.group(1), m.group(2)


def main():
    outd = os.environ["OUTD"]
    real = tc.shutil.rmtree

    def rm(d, **kw):
        p = os.path.join(d, "p", "x.types")
        if os.path.exists(p): count(p)
        real(d, **kw)
    tc.shutil.rmtree = rm
    rc = tc.main()

    # kinds: constrained variables
    constrained = {(d, v) for d, (ks, _) in DEFS.items() for v, k in ks.items() if k in CONSTRAINED}
    rows = {(d, v) for d, (ks, _) in DEFS.items() for v, k in ks.items() if k == "row"}
    # sig# mismatch between uses and definitions
    mismatch = sum(1 for c, h, _ in USES if c in DEFS and DEFS[c][1] != h)
    unknown_callee = sum(1 for c, _, _ in USES if c not in DEFS)

    by_callee = collections.defaultdict(list)
    for u in USES: by_callee[u[0]].append(u)
    parsed = {}

    def tree(text):
        t = parsed.get(text)
        if t is None:
            t = parsed[text] = parse_type(text)
        return t

    # equatable marks: fixpoint, from the roots
    eq = set(ROOTS)
    work = list(ROOTS)
    owner_uses = collections.defaultdict(list)
    while work:
        cv = work.pop()
        for (c, h, binds) in by_callee.get(cv[0], ()):
            for v, text in binds:
                if v != cv[1]: continue
                acc = set(); tokens_of(tree(text), acc)
                for tk in acc:
                    key = tok_split(tk)
                    if key not in eq:
                        eq.add(key); work.append(key)
    # a marked variable of a def of this dump only matters if the def exists
    eq = {k for k in eq if k[0] in DEFS}
    eq_only = {k for k in eq if k not in constrained}      # not already keyed by its kind

    def clones(marked, product=True):
        """distinct instances of the marked variables of each callee, with closure over polymorphic callers"""
        marked_by = collections.defaultdict(set)
        for d, v in marked: marked_by[d].add(v)
        keys = collections.defaultdict(set)        # callee -> set of tuple((v, text))
        nonconc = 0
        product_callees = set()
        # all uses of a callee with marked variables
        pending = collections.defaultdict(list)    # owner id -> uses that mention its tokens in a marked position
        queue = []
        for (c, h, binds) in USES:
            mv = marked_by.get(c)
            if not mv: continue
            part = [(v, tree(t)) for v, t in binds if v in mv]
            if len(part) != len(mv):
                continue                            # a marked variable not instantiated here: identity or dead
            acc = set()
            for _, t in part: tokens_of(t, acc)
            if not acc:
                key = tuple((v, show(t)) for v, t in sorted(part))
                if key not in keys[c]:
                    keys[c].add(key); queue.append((c, key))
            else:
                nonconc += 1
                for o in {tok_split(tk)[0] for tk in acc}: pending[o].append((c, part))
        # closure: a clone of O gives concrete instances to the uses inside O's body
        seen_pair = set()
        while queue:
            o, key = queue.pop()
            env_o = {"<<%s|%s>>" % (o, v): parse_type(t) if False else tree(t) for v, t in key}
            for (c, part) in pending.get(o, ()):
                acc = set()
                for _, t in part: tokens_of(t, acc)
                owners = {tok_split(tk)[0] for tk in acc}
                if owners != {o}:
                    # mixed owners (a local definition using an enclosing variable): take the clones of the others
                    others = [x for x in owners if x != o]
                    if any(x not in keys for x in others): continue
                    import itertools
                    if not product: continue
                    product_callees.add(c)
                    combos = itertools.product(*[sorted(keys[x]) for x in others])
                else:
                    combos = [()]
                for combo in combos:
                    env = dict(env_o)
                    for x, k in zip([x for x in owners if x != o], combo):
                        env.update({"<<%s|%s>>" % (x, v): tree(t) for v, t in k})
                    new = tuple((v, show(subst(t, env))) for v, t in sorted(part))
                    if any("<<" in t for _, t in new): continue
                    if new not in keys[c]:
                        keys[c].add(new); queue.append((c, new))
        return keys, nonconc, marked_by, product_callees

    def summary(marked, product=True):
        keys, nonconc, marked_by, pcal = clones(marked, product)
        sizes = sorted((len(v) for v in keys.values()), reverse=True)
        hist = collections.Counter(min(s, 5) for s in sizes)
        top = sorted(keys.items(), key=lambda kv: -len(kv[1]))[:8]
        return {"callees_marked": len(marked_by), "callees_with_clones": len(keys), "clones": sum(sizes),
                "hist(1..5+)": [hist.get(i, 0) for i in range(1, 6)], "max": sizes[0] if sizes else 0,
                "nonconcrete_uses": nonconc, "callees_using_product": len(pcal), "top": [(c, len(v)) for c, v in top]}

    res = {"defs": len(DEFS), "distinct uses": len(USES), "sig_mismatch": mismatch, "use_of_unknown_callee": unknown_callee,
           "equatable_marked_vars": len(eq), "equatable_only_vars(not number/comparable/appendable)": len(eq_only),
           "row_vars": len(rows)}
    for k in CONSTRAINED:
        res[k] = summary({(d, v) for d, (ks, _) in DEFS.items() for v, kk in ks.items() if kk == k})
    res["equatable"] = summary(eq)
    res["equatable_without_product"] = summary(eq, False)
    res["number_without_product"] = summary({(d, v) for d, (ks, _) in DEFS.items() for v, kk in ks.items() if kk == "number"}, False)
    res["comparable_without_product"] = summary({(d, v) for d, (ks, _) in DEFS.items() for v, kk in ks.items() if kk == "comparable"}, False)
    gl = collections.Counter(classify(c) for c in {c for c, _, _ in USES if c not in DEFS})
    res["unknown_callees_global_distinct_by_kind"] = dict(gl)
    res["unknown_global_other_examples"] = sorted(c for c in {c for c, _, _ in USES if c not in DEFS} if classify(c) == "other")[:25]
    res["mismatch_within_one_dump"] = len(LOCAL_MISMATCH)
    res["mismatch_examples"] = sorted(LOCAL_MISMATCH)[:15]
    res["unknown_callee_uses_by_kind(per dump, distinct)"] = dict(UNKNOWN)
    res["unknown_other_examples"] = UNKNOWN_OTHER.most_common(25)
    res["equatable_only"] = summary(eq_only)
    res["row"] = summary(rows)
    res["row_keys_note"] = "row variable instance = the record's remaining fields"
    json.dump(res, open(os.path.join(outd, "scheme_stats.json"), "w"), indent=1)
    print(json.dumps(res, indent=1))
    return rc


if __name__ == "__main__":
    sys.exit(main())
