#!/usr/bin/env python3
"""Cases for the regex differential tests: random patterns of the supported subset (and some garbage) with random subjects, from a fixed seed,
plus the hand-written edge cases. Output: lines "flags<TAB>pattern<TAB>subject" with \\n, \\t and \\\\ escaped (the format of re_driver.c and ref.js).
  gen_cases.py [--seed N] [--random K] > cases.tsv"""
import argparse, random

HAND = [  # (flags 1=i 2=m, pattern, subject)
    # empty matches
    (0, "", "abc"), (0, "", ""), (0, "a*", "baac"), (0, "x*", "ab"), (0, "[a-z]*", "ab 12 c"), (0, "a|", "ba"), (0, "(a|b)*", "ab"), (0, "\\b", "foo bar"),
    (0, "^", "a\nb"), (2, "^", "a\nb"), (2, "$", "a\nb\n"), (0, "$", "ab"), (0, "(?:)", "ab"), (0, "()", "ab"), (0, "(a*)*", "aab"), (0, "(a*)+", "b"),
    (0, "(a*)?", "b"), (0, "(a?)*?b", "aab"), (0, "(?:a?)*", "aaa"), (0, "(?:a|b?)+", "abab"), (0, "(a|ab)(c|bcd)(d*)", "abcd"),
    # greedy and lazy
    (0, "a.+?c", "abcabc"), (0, "a.+c", "abcabc"), (0, "a.*?", "aaa"), (0, "a+?", "aaa"), (0, "a{2,3}", "aaaaaaa"), (0, "a{2,3}?", "aaaaaaa"), (0, "a{2}", "aaaaa"),
    (0, "a{2,}", "aaaaa"), (0, "a{0}", "aa"), (0, "a{,2}", "a{,2}"), (0, "a{", "a{"), (0, "a{1", "a{1"), (0, "x{1,2", "x{1,2"), (0, "(ab){2}", "ababab"),
    (0, "(a|b){2,3}c", "abababc"), (0, "(?:ab)+?", "abab"), (0, "a??b", "ab"), (0, "(a+)(a+)", "aaaa"), (0, "(a+?)(a+)", "aaaa"),
    # alternation, classes
    (0, "a|ab", "ab"), (0, "ab|a", "ab"), (0, "(a|ab)(c|bcd)", "abcd"), (0, "[abc]+", "xabcabcx"), (0, "[^abc]+", "xabcabcx"), (0, "[a-c-e]+", "ab-ce"),
    (0, "[\\d-z]+", "1-z"), (0, "[\\w-]+", "a-b c"), (0, "[\\]]", "]"), (0, "[]", "a"), (0, "[^]", "a\n"), (0, "[a-]", "a-"), (0, "[-a]", "a-"), (0, "[\\b]", "\b"),
    (0, "[\\s\\S]", "a\n"), (0, "\\D+", "ab12c"), (0, "\\W+", "ab, c"), (0, "\\S+", "ab cd"), (0, "[\\D]", "1a"), (0, "[^\\d]", "1a"), (0, "[z-a]", "a"),
    (0, "\\s", "a b\tc\nd\u00a0e\u2003f\ufeffg"), (0, "a.b", "a\nb"), (0, "a.b", "a\rb"), (0, "a.b", "a\u2028b"), (0, "a.b", "a\u00a0b"),
    # anchors, boundaries
    (0, "\\bfoo\\b", "foo xfoo foo"), (0, "\\Boo\\B", "fooo oo"), (0, "^a", "a\na"), (2, "^a", "a\na"), (2, "a$", "a\na"), (0, "^$", ""), (2, "^$", "a\n\nb"),
    (0, "^*", "a"), (0, "$+", "a"), (0, "\\b+", "a"), (0, "(?=a)+", "a"), (0, "(?=a)*b", "ab"), (0, "(?<=a)+", "a"),
    # groups and backreferences
    (0, "(a)\\1", "aab"), (0, "(a)|(b)", "b"), (0, "(a)?b", "b"), (0, "(a)(b)?", "ac a ab"), (0, "((a)b)", "ab"), (0, "(?:a)(b)", "ab"), (0, "(a*)\\1", "aaaa"),
    (0, "\\1(a)", "aa"), (0, "(a)\\2", "a\x02"), (0, "\\1", "\x01"), (0, "\\8", "8"), (0, "(a)\\10", "a\x08"), (1, "(a)\\1", "aA"), (0, "(?:(a)|b)\\1", "b"),
    (0, "(a)|\\1b", "b"), (0, "(\\2a)(b)", "ab"), (0, "(a)(?:\\1)*", "aaa"), (0, "(?:(a)|(b))+", "ab"), (0, "(?:(a)|(b))+?c", "abc"),
    # lookaround
    (0, "a(?=b)", "ab ac"), (0, "a(?!b)", "ab ac"), (0, "(?<=a)b", "ab cb"), (0, "(?<!a)b", "ab cb"), (0, "(?<=(a))b", "ab"), (0, "(?<=(\\d+))x", "123x"),
    (0, "(?<=\\1(a))b", "aab"), (0, "(?=(a))\\1", "a"), (0, "(?!(a))b", "b"), (0, "(?=a)(?=ab)ab", "ab"), (0, "(?<=ab|c)d", "abd cd"), (0, "(?<=a+)b", "aab"),
    (0, "(?<=a*?)b", "aab"), (0, "(?<=^|,)x", "x,x"), (0, "(?<=(?<=a)b)c", "abc"), (0, "(?<=a(?=b))b", "ab"), (0, "(?=(?!a))", "ab"),
    # escapes
    (0, "\\u00e9", "\u00e9"), (0, "\\x41", "A"), (0, "\\x4", "x4"), (0, "\\u12", "u12"), (0, "\\cA", "\x01"), (0, "\\c1", "\\c1"), (0, "[\\c1]", "\x11"),
    (0, "\\012", "\n"), (0, "\\101", "A"), (0, "a\\.b", "a.b"), (0, "a\\.b", "axb"), (0, "\\-", "-"), (0, "\\z", "z"), (0, "\\/", "/"), (0, "\\", "a"),
    (0, "\\ud83d\\ude23", "x"), (0, "\\n\\r\\t\\f\\v", "\n\r\t\f\v"), (0, "]", "]"), (0, "}", "}"), (0, "{", "{"), (0, "a|*", "a"), (0, "(", "a"), (0, ")", "a"),
    (0, "a)", "a"), (0, "[a", "a"), (0, "(?", "a"), (0, "(?x)", "a"), (0, "a**", "a"), (0, "a+*", "a"), (0, "a{2}{3}", "aaaaaa"), (0, "{1}", "a"), (0, "x{2,1}", "xx"),
    (0, "*a", "a"), (0, "+", "a"), (0, "?", "a"), (0, "(*)", "a"), (0, "(|a)", "a"), (0, "a|b|c", "cba"), (0, "(?:a|b|c)+", "cbaz"),
    # case insensitive
    (1, "abc", "xABCx"), (1, "[a-c]", "ABCabc"), (1, "\u00e9", "\u00c9"), (1, "ss", "\u00df"), (1, "\u00df", "SS"), (1, "[^a]", "aAb"), (1, "\\w", "\u017f"), (1, "k", "\u212a"),
    (1, "\u03c3", "\u03a3\u03c2"), (1, "[\u03c3]+", "\u03a3\u03c2\u03c3"), (1, "\u00b5", "\u03bc\u039c"), (1, "(a)\\1", "aA"), (1, "\\u00e9", "\u00c9"),
    (1, "[\\u00e0-\\u00ff]+", "\u00c0\u00df\u00e9\u00d7"), (1, "[A-Z]+", "abcXYZ"), (1, "\\bFOO\\b", "foo"), (1, "(?<=A)b", "aB"), (1, "(?<=a)B", "aAb"),
    (1, "i", "\u0130\u0131I"), (1, "\u0131", "I"),
    # misc
    (0, "x*y+$", "xxxyyyz xxxyyy"), (0, "(\\d+)-(\\d+)", "10-20 30-40"), (0, "[0-9]+", "a1b22c333"), (0, "[oi]n a (\\w+)", "I am on a boat in a lake."),
    (0, "\\w+@\\w+", "me@host x@y"), (0, ", *", "a, b,c,   d"), (0, "a|b|", "xbz"),
    (0, "(?<n>a)", "ab a"), (0, "(?<n>a)\\k<n>", "aa ab"), (0, "\\k<n>", "k<n>"), (0, "\\k", "ak"), (0, "(?<=a)(?<n>b)", "ab cb"), (0, "(?<y>\\d+)-(?<m>\\d+)", "10-20 30-40"),
    (0, "(?<a>x)(?<b>y)?\\k<b>", "xy x"), (0, "\\k<n>(?<n>a)", "a"), (0, "(?<n>a)(?<n>b)", "ab"), (0, "(?<n>a)\\k<m>", "aa"), (0, "(?<n>a)\\k", "aa"), (0, "(?<n>a)[\\k]", "ak"),
    (0, "(?<1a>x)", "x"), (0, "(?<>x)", "x"), (0, "(?<n", "x"), (0, "(?<_$a1>x)\\k<_$a1>", "xx"), (1, "(?<n>a)\\k<n>", "aA"), (0, "(?<n>a)|b\\k<n>", "b a"), (0, "(?<n>a)+\\k<n>?", "aaa"),
    (0, "(?:(?:a|b)*c)*d", "abcabcd"), (0, "((a)|(b))+", "ab"), (0, "(z)((a+)?(b+)?(c))*", "zaacbbbcac"),
]

ATOMS = ["a", "b", "c", "x", "0", "1", " ", "-", "_", ".", "\\d", "\\w", "\\s", "\\D", "\\W", "\\S", "[ab]", "[^ab]", "[a-c]", "[^a-c ]", "[\\d_]", "[0-9a-f]", "[\\w-]", "\u00e9", "\u00c9", "\\.",
         "\\b", "\\B", "^", "$", "\\u0061", "\\x62", "\\n"]
SUBJ = "aabbcx01 _-.\n\u00e9\u00c9AB"


def rnd_pat(r, depth=0):
    n = r.randint(1, 4)
    alts = []
    for _ in range(r.randint(1, 3 if depth < 3 else 1)):
        seq = ""
        for _ in range(n):
            k = r.random()
            if k < 0.62 or depth > 2:
                a = r.choice(ATOMS)
            elif k < 0.80:
                a = ("(?<n%d>" % r.randint(1, 3) if r.random() < 0.2 else "(") + rnd_pat(r, depth + 1) + ")"
            elif k < 0.88:
                a = "(?:" + rnd_pat(r, depth + 1) + ")"
            elif k < 0.94:
                a = r.choice(["(?=", "(?!", "(?<=", "(?<!"]) + rnd_pat(r, depth + 1) + ")"
            else:
                a = r.choice(["\\1", "\\2", "\\1", "\\3", "\\k<n1>", "\\k<n2>"])
            if r.random() < 0.38 and a not in ("\\b", "\\B", "^", "$") and not a.startswith(("(?<=", "(?<!")):
                a += r.choice(["*", "+", "?", "*?", "+?", "??", "{2}", "{1,2}", "{0,2}?", "{2,}"])
            seq += a
        alts.append(seq)
    return "|".join(alts)


def esc(s):
    return s.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--random", type=int, default=300)
    a = ap.parse_args()
    r = random.Random(a.seed)
    cases = list(HAND)
    for _ in range(a.random):
        p = rnd_pat(r)
        if r.random() < 0.05:  # garbage: a random character inserted
            i = r.randint(0, len(p))
            p = p[:i] + r.choice("()[]{}*+?|\\^$.-,") + p[i:]
        for _ in range(2):
            s = "".join(r.choice(SUBJ) for _ in range(r.randint(0, 12)))
            cases.append((r.choice([0, 0, 0, 1, 2, 3]), p, s))
    for f, p, s in cases:
        print("%d\t%s\t%s" % (f, esc(p), esc(s)))


if __name__ == "__main__":
    main()
