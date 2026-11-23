app [main!] {
    cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
}

# P1 version A in Roc: a JSON parser built from a small parser combinator library modelled on elm/parser,
# translated from targets/p1/src/JSONComb.elm and JSONTree.elm (planning chat, NOT COMPILED: see the list of
# uncertain spots in the reply). Run:  roc JSONComb.roc -- JSON_50mb.JSON
# Expected 50 MB: nodes=4131606 sum64=11196337623888 strlen=10937203 depth=12
# Expected  1 MB: nodes=87689 sum64=237203670393 strlen=233720 depth=12
#
# Differences from the Elm version:
#  - the text is read from a file (List U8) and not generated in the program;
#  - strings are kept as List U8 (UTF-8 bytes, \u escapes encoded) and counted in code points for the checksum;
#  - sepBy is a small loop that carries the list (Roc lists are arrays: a cons would be O(n) and a shared accumulator
#    would be copied by append, so the Elm sepBy/loop shape would be quadratic here).

import cli.Stdout
import cli.Path
import cli.Monotonic exposing [now!, since]
import cli.Duration exposing [to_millis]

# ---------------------------------------------------------------- the value tree and the checksum

JSON := [
    JNull,
    JBool(Bool),
    JNum(F64),
    JStr(List(U8)),
    JArr(List(JSON)),
    JObj(List((List(U8), JSON))),
]

Summary : { nodes : U64, sum : F64, strlen : U64, depth : U64 }

# code points of UTF-8 bytes: the bytes that are not continuation bytes
codePoints : List(U8) -> U64
codePoints = |bytes| {
  bytes.fold(0, |n, b| if (b.bitwise_and(0xC0) == 0x80) n else n + 1)
}

fold : U64, JSON, Summary -> Summary
fold = |d, j, acc| {
  a1 = { ..acc, nodes: acc.nodes + 1, depth: if (d > acc.depth) d else acc.depth }
  match j {
    JNull => a1
    JBool(_) => a1
    JNum(x) => { ..a1, sum: a1.sum + x }
    JStr(s) => { ..a1, strlen: a1.strlen + codePoints(s) }
    JArr(xs) => xs.fold(a1, |a, x| fold(d + 1, x, a))
    JObj(ps) => ps.fold(a1, |a, kv| fold(d + 1, kv.1, { ..a, strlen: a.strlen + codePoints(kv.0) }))
  }
}

summarize : JSON -> Summary
summarize = |j| fold(1, j, { nodes: 0, sum: 0.0, strlen: 0, depth: 0 })

report : Summary -> Str
report = |s| {
  sum64 = match (s.sum * 64.0).floor_to_i64_try() {
    Ok(i) => i
    Err(_) => crash "sum64 overflow"
  }
  "nodes=${s.nodes.to_str()} sum64=${sum64.to_str()} strlen=${s.strlen.to_str()} depth=${s.depth.to_str()}"
}

# ---------------------------------------------------------------- the combinator library

State : { src : List(U8), offset : U64 }

Step(a) : [Good(Bool, a, State), Bad(Bool, Str)]

Parser(a) : State -> Step(a)

Loop(state, a) : [More(state), Done(a)]

succeed : a -> Parser(a)
succeed = |a| |s| Good(Bool.False, a, s)

map : (a -> b), Parser(a) -> Parser(b)
map = |f, p| |s| {
  match p(s) {
    Good(c, a, s1) => Good(c, f(a), s1)
    Bad(c, m) => Bad(c, m)
  }
}

map2 : (a, b -> c), Parser(a), Parser(b) -> Parser(c)
map2 = |f, pa, pb| |s| {
  match pa(s) {
    Bad(c, m) => Bad(c, m)
    Good(c1, a, s1) =>
      match pb(s1) {
        Bad(c2, m) => Bad(c1 or c2, m)
        Good(c2, b, s2) => Good(c1 or c2, f(a, b), s2)
      }
  }
}

andThen : (a -> Parser(b)), Parser(a) -> Parser(b)
andThen = |f, pa| |s| {
  match pa(s) {
    Bad(c, m) => Bad(c, m)
    Good(c1, a, s1) =>
      match f(a)(s1) {
        Bad(c2, m) => Bad(c1 or c2, m)
        Good(c2, b, s2) => Good(c1 or c2, b, s2)
      }
  }
}

# the functions given to keep are curried lambdas: |a| |b| ...
keep : Parser((a -> b)), Parser(a) -> Parser(b)
keep = |pf, pa| map2(|f, a| f(a), pf, pa)

ignore : Parser(keep), Parser(skip) -> Parser(keep)
ignore = |pk, ps| map2(|k, _| k, pk, ps)

oneOf : List(Parser(a)) -> Parser(a)
oneOf = |ps| |s| oneOfHelp(s, ps, 0)

oneOfHelp : State, List(Parser(a)), U64 -> Step(a)
oneOfHelp = |s, ps, i| {
  match ps.get(i) {
    Err(_) => Bad(Bool.False, "oneOf")
    Ok(p) =>
      match p(s) {
        Good(c, a, s1) => Good(c, a, s1)
        Bad(c, m) => if (c) Bad(c, m) else oneOfHelp(s, ps, i + 1)
      }
  }
}

lazy : ({} -> Parser(a)) -> Parser(a)
lazy = |thunk| |s| thunk({})(s)

loop : state, (state -> Parser(Loop(state, a))) -> Parser(a)
loop = |st, f| |s| loopHelp(Bool.False, st, f, s)

loopHelp : Bool, state, (state -> Parser(Loop(state, a))), State -> Step(a)
loopHelp = |p, st, f, s| {
  match f(st)(s) {
    Good(c, step, s1) =>
      match step {
        More(st1) => loopHelp(p or c, st1, f, s1)
        Done(a) => Good(p or c, a, s1)
      }
    Bad(c, m) => Bad(p or c, m)
  }
}

# ---------------------------------------------------------------- primitives (they read the source)

byteAt : U64, List(U8) -> I64
byteAt = |i, src| {
  match src.get(i) {
    Ok(b) => b.to_i64()
    Err(_) => -1
  }
}

symbol : I64 -> Parser({})
symbol = |code| |s| {
  if (byteAt(s.offset, s.src) == code) {
    Good(Bool.True, {}, { ..s, offset: s.offset + 1 })
  } else {
    Bad(Bool.False, "symbol")
  }
}

word : List(I64) -> Parser({})
word = |codes| |s| wordHelp(codes, 0, s.offset, s)

wordHelp : List(I64), U64, U64, State -> Step({})
wordHelp = |codes, i, start, s| {
  match codes.get(i) {
    Err(_) => Good(Bool.True, {}, s)
    Ok(c) =>
      if (byteAt(s.offset, s.src) == c) {
        wordHelp(codes, i + 1, start, { ..s, offset: s.offset + 1 })
      } else {
        Bad(s.offset > start, "word")
      }
  }
}

chompIf : (I64 -> Bool) -> Parser({})
chompIf = |isGood| |s| {
  b = byteAt(s.offset, s.src)
  if (b >= 0 and isGood(b)) {
    Good(Bool.True, {}, { ..s, offset: s.offset + 1 })
  } else {
    Bad(Bool.False, "chompIf")
  }
}

chompWhile : (I64 -> Bool) -> Parser({})
chompWhile = |isGood| |s| {
  o = chompWhileHelp(isGood, s.src, s.offset)
  Good(o > s.offset, {}, { ..s, offset: o })
}

chompWhileHelp : (I64 -> Bool), List(U8), U64 -> U64
chompWhileHelp = |isGood, src, o| {
  b = byteAt(o, src)
  if (b >= 0 and isGood(b)) chompWhileHelp(isGood, src, o + 1) else o
}

chompSome : (I64 -> Bool) -> Parser({})
chompSome = |isGood| ignore(chompIf(isGood), chompWhile(isGood))

getOffset : Parser(U64)
getOffset = |s| Good(Bool.False, s.offset, s)

# the bytes that the parser p consumed
getChompedBytes : Parser(a) -> Parser(List(U8))
getChompedBytes = |p| |s| {
  match p(s) {
    Good(c, _, s1) => Good(c, s.src.sublist({ start: s.offset, len: s1.offset - s.offset }), s1)
    Bad(c, m) => Bad(c, m)
  }
}

# the value of one or more decimal digits (fails without consuming when there is none)
int10 : Parser(U64)
int10 = |s| {
  o = chompWhileHelp(isDigit, s.src, s.offset)
  if (o > s.offset) {
    Good(Bool.True, digitsValue(s.src, s.offset, o, 0), { ..s, offset: o })
  } else {
    Bad(Bool.False, "digit")
  }
}

digitsValue : List(U8), U64, U64, U64 -> U64
digitsValue = |src, i, end, acc| {
  if (i >= end) acc else digitsValue(src, i + 1, end, acc * 10 + (byteAt(i, src) - 48).to_u64_wrap())
}

pow10 : U64 -> F64
pow10 = |n| if (n == 0) 1.0 else 10.0 * pow10(n - 1)

applySign : Bool, F64 -> F64
applySign = |neg, x| if (neg) 0.0 - x else x

minus : Parser(Bool)
minus = oneOf([map(|_| Bool.True, symbol(45)), succeed(Bool.False)])

number : Parser(F64)
number = map2(|neg, x| applySign(neg, x), minus, unsignedNumber)

unsignedNumber : Parser(F64)
unsignedNumber =
  andThen(|ip| andThen(|fr| map(|ex| (ip.to_f64() + fr) * ex, exponent), fraction), int10)

fraction : Parser(F64)
fraction =
  oneOf([
    keep(map(|_| |f| f, symbol(46)), fractionDigits),
    succeed(0.0),
  ])

fractionDigits : Parser(F64)
fractionDigits =
  andThen(|o0| andThen(|v| map(|o1| v.to_f64() / pow10(o1 - o0), getOffset), int10), getOffset)

exponent : Parser(F64)
exponent =
  oneOf([
    keep(map(|_| |e| e, oneOf([symbol(101), symbol(69)])), exponentBody),
    succeed(1.0),
  ])

exponentBody : Parser(F64)
exponentBody =
  andThen(
    |neg| map(|e| exponentFactor(neg, e), int10),
    oneOf([map(|_| Bool.False, symbol(43)), map(|_| Bool.True, symbol(45)), succeed(Bool.False)]),
  )

exponentFactor : Bool, U64 -> F64
exponentFactor = |neg, e| if (neg) 1.0 / pow10(e) else pow10(e)

# ---------------------------------------------------------------- the JSON grammar

isDigit : I64 -> Bool
isDigit = |b| b >= 48 and b <= 57

isSpace : I64 -> Bool
isSpace = |b| b == 32 or b == 10 or b == 13 or b == 9

isPlain : I64 -> Bool
isPlain = |b| b != 34 and b != 92

spaces : Parser({})
spaces = chompWhile(isSpace)

lexeme : Parser(a) -> Parser(a)
lexeme = |p| ignore(p, spaces)

nullWord : List(I64)
nullWord = [110, 117, 108, 108]

trueWord : List(I64)
trueWord = [116, 114, 117, 101]

falseWord : List(I64)
falseWord = [102, 97, 108, 115, 101]

# value, jarray, jobject and member are mutually recursive, so they are functions
# (the Elm version has the same shape: jarray, jobject and member are functions of ())
value : Parser(JSON)
value = |s| {
  thunk = |{}| oneOf([jarray({}), jobject({}), jstring, jnumber, jtrue, jfalse, jnull])
  lazy(thunk)(s)
}

jnull : Parser(JSON)
jnull = map(|_| JNull, lexeme(word(nullWord)))

jtrue : Parser(JSON)
jtrue = map(|_| JBool(Bool.True), lexeme(word(trueWord)))

jfalse : Parser(JSON)
jfalse = map(|_| JBool(Bool.False), lexeme(word(falseWord)))

jnumber : Parser(JSON)
jnumber = map(|n| JSON.JNum(n), lexeme(number))

jstring : Parser(JSON)
jstring = map(|s| JSON.JStr(s), stringToken)

stringToken : Parser(List(U8))
stringToken =
  ignore(
    keep(ignore(succeed(unescape), symbol(34)), getChompedBytes(stringBody)),
    lexeme(symbol(34)),
  )

stringBody : Parser({})
stringBody =
  loop({}, |_| oneOf([map(|_| More({}), stringChunk), succeed(Done({}))]))

stringChunk : Parser({})
stringChunk =
  oneOf([chompSome(isPlain), ignore(symbol(92), chompIf(|_| Bool.True))])

jarray : {} -> Parser(JSON)
jarray = |{}|
  ignore(
    keep(ignore(succeed(|a| JSON.JArr(a)), lexeme(symbol(91))), sepBy(value, lexeme(symbol(44)))),
    lexeme(symbol(93)),
  )

jobject : {} -> Parser(JSON)
jobject = |{}|
  ignore(
    keep(ignore(succeed(|o| JSON.JObj(o)), lexeme(symbol(123))), sepBy(member({}), lexeme(symbol(44)))),
    lexeme(symbol(125)),
  )

member : {} -> Parser((List(U8), JSON))
member = |{}|
  map2(|k, v| (k, v), stringToken, keep(map(|_| |v| v, lexeme(symbol(58))), value))

# zero or more items separated by sep (see the note at the top about why this is not the Elm shape)
sepBy : Parser(a), Parser({}) -> Parser(List(a))
sepBy = |item, sep| |s| {
  match item(s) {
    Bad(c, m) => if (c) Bad(c, m) else Good(Bool.False, [], s)
    Good(c1, x, s1) => sepByHelp(item, sep, c1, [x], s1)
  }
}

sepByHelp : Parser(a), Parser({}), Bool, List(a), State -> Step(List(a))
sepByHelp = |item, sep, p, acc, s| {
  step = keep(map(|_| |y| y, sep), item)
  match step(s) {
    Good(c, y, s1) => sepByHelp(item, sep, p or c, acc.append(y), s1)
    Bad(c, m) => if (c) Bad(c, m) else Good(p, acc, s)
  }
}

endOfInput : Parser({})
endOfInput = |s| {
  if (s.offset == s.src.len()) Good(Bool.False, {}, s) else Bad(Bool.False, "end of input")
}

document : Parser(JSON)
document = ignore(keep(ignore(succeed(|x| x), spaces), value), endOfInput)

run : Parser(a), List(U8) -> Try(a, Str)
run = |p, src| {
  match p({ src: src, offset: 0 }) {
    Good(_, a, _) => Ok(a)
    Bad(_, m) => Err(m)
  }
}

# ---------------------------------------------------------------- escapes (on the bytes of a string token)

unescape : List(U8) -> List(U8)
unescape = |raw| {
  if (raw.contains(92)) unescapeFrom(raw, 0, List.with_capacity(raw.len())) else raw
}

unescapeFrom : List(U8), U64, List(U8) -> List(U8)
unescapeFrom = |raw, i, acc| {
  match raw.get(i) {
    Err(_) => acc
    Ok(b) =>
      if (b != 92) {
        unescapeFrom(raw, i + 1, acc.append(b))
      } else {
        match raw.get(i + 1) {
          Err(_) => acc
          Ok(c) =>
            if (c == 110) {
              unescapeFrom(raw, i + 2, acc.append(10))
            } else if (c == 116) {
              unescapeFrom(raw, i + 2, acc.append(9))
            } else if (c == 98) {
              unescapeFrom(raw, i + 2, acc.append(8))
            } else if (c == 102) {
              unescapeFrom(raw, i + 2, acc.append(12))
            } else if (c == 114) {
              unescapeFrom(raw, i + 2, acc.append(13))
            } else if (c == 117) {
              code = hexAt(raw, i + 2) * 4096 + hexAt(raw, i + 3) * 256 + hexAt(raw, i + 4) * 16 + hexAt(raw, i + 5)
              unescapeFrom(raw, i + 6, utf8Append(acc, code))
            } else {
              unescapeFrom(raw, i + 2, acc.append(c))
            }
        }
      }
  }
}

hexAt : List(U8), U64 -> U64
hexAt = |raw, i| {
  n = byteAt(i, raw)
  if (n >= 97) (n - 87).to_u64_wrap() else if (n >= 65) (n - 55).to_u64_wrap() else (n - 48).to_u64_wrap()
}

# append the UTF-8 encoding of a code point below 65536
utf8Append : List(U8), U64 -> List(U8)
utf8Append = |acc, code| {
  if (code < 128) {
    acc.append(code.to_u8_wrap())
  } else if (code < 2048) {
    acc.append((code.shr_zf_wrap(6) + 192).to_u8_wrap()).append((code.bitwise_and(63) + 128).to_u8_wrap())
  } else {
    acc.append((code.shr_zf_wrap(12) + 224).to_u8_wrap())
      .append((code.shr_zf_wrap(6).bitwise_and(63) + 128).to_u8_wrap())
      .append((code.bitwise_and(63) + 128).to_u8_wrap())
  }
}

# ---------------------------------------------------------------- main

main! = |args| {
  path = match args.get(1) {
    Ok(a) => Path.from_os_str(a)
    Err(_) => crash "usage: roc JSONComb.roc -- <file.JSON>"
  }
  bytes = match Path.read_bytes!(path) {
    Ok(b) => b
    Err(_) => crash "cannot read the file"
  }
  start = now!()
  answer = match run(document, bytes) {
    Ok(j) => report(summarize(j))
    Err(e) => "error ${e}"
  }
  stop = now!()
  elapsed = stop.since(start).to_millis()
  Stdout.line!("${answer} (parse ${elapsed.to_str()} ms)")
}
