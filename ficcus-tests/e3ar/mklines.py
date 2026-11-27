#!/usr/bin/env python3
"""E3a review: writes the lines sent by host/drive.c and ref/drive.js (stdout)."""
L = []
def s(p, j): L.append("%s %s" % (p, j))
for j in ["1", "-0", "1.0", "1.5", "9007199254740993", "9223372036854775807", "9223372036854775808", "-9223372036854775808",
          "-9223372036854775809", "1e300", "1e400", "\"1\"", "null", "true", "[]"]:
    s("pInt", j)
for j in ["1e400", "-1e400", "1", "5e-324", "\"x\""]:
    s("pFloat", j)
for j in ["{}", "{\"a\":1}", "{\"a\":1,\"b\":1}", "{\"a\":1,\"b\":1,\"ab\":1}", "{\"a\":1,\"b\":1,\"ab\":1,\"abc\":\"x\"}",
          "{\"a\":\"x\",\"b\":\"x\",\"ab\":\"x\",\"abc\":\"x\"}", "[1,2]", "null"]:
    s("pRec3", j)
for j in ["[1,2]", "[]", "\"abc\"", "{\"length\":3}", "{\"length\":\"x\"}"]:
    s("pLen", j)
for j in ["{}", "{\"constructor\":1}", "[]"]:
    s("pCtor", j)
for j in ["{}", "{\"constructor\":[1]}"]:
    s("pCtorV", j)
for j in ["{}", "{\"café\":1}", "{\"café\":1,\"ü\":\"x\"}", "{\"café\":1,\"ü\":2}"]:
    s("pUni", j)
for j in ["\"a\\u00e9\\ud83d\\ude00\"", "\"\\ud800\"", "\"\\udc00x\"", "\"\\u0000\"", "1"]:
    s("pStr", j)
for j in ["null", "1", "\"x\"", "[null]"]:
    s("pMM", j)
for j in ["[[1],[2,3]]", "[[1],[2,\"x\"]]", "[1]", "[[]]", "{\"0\":[1]}"]:
    s("pNest", j)
for j in ["[1,\"a\"]", "[1,\"a\",3]", "[1]", "[\"a\",1]", "{\"0\":1,\"1\":\"a\"}"]:
    s("pTup", j)
for n in [0, 1, 31, 32, 33, 63, 64, 65, 1023, 1024, 1025, 1055, 1056, 1057, 32767, 32768, 32769, 32799, 32800, 32801, 32831, 32832,
          33823, 33824, 33825]:
    s("pArr", "[" + ",".join(str(i) for i in range(n)) + "]")
s("pArr", "[" + ",".join(str(i) for i in range(32800)) + ",\"x\"]")
s("pArr", "[" + ",".join(str(i) for i in range(32799)) + ",1.5,2]")
deep = 2000
s("pVal", "[" * deep + "]" * deep)
s("pNest", "[" * 3 + "]" * 3)
s("pInt", "[" * deep + "]" * deep)
print("\n".join(L))
