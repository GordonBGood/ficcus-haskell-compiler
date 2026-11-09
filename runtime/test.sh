#!/bin/sh
# Compile and run the standalone runtime tests (test_*.c, output in test_*.expected) with every available C
# compiler, no warnings allowed. SAN=1 adds -fsanitize=undefined. Also checks that fic_closure.h is what
# gen_closure.py generates.
here=$(cd "$(dirname "$0")" && pwd)
rt=$here/../../targets/c
tmp=${TMPDIR:-/tmp}
bad=0
if python3 "$here/gen_closure.py" | cmp -s - "$here/fic_closure.h"; then echo "ok   fic_closure.h is generated"; else echo "FAIL fic_closure.h differs from gen_closure.py"; bad=1; fi
for cc in gcc clang; do
  command -v $cc >/dev/null || continue
  for t in test_runtime test_closure test_bitwise test_jsarray test_ustring test_fdlibm; do
    if $cc -std=c99 -pedantic -Wall -Wextra -Wno-unused-function -ffp-contract=off -O2 ${SAN:+-fsanitize=undefined} \
         -I "$rt" -I "$here" "$here/$t.c" -o "$tmp/fic_$t.$cc" -lm 2>"$tmp/fic_$t.$cc.err" && [ ! -s "$tmp/fic_$t.$cc.err" ]; then
      ASAN_OPTIONS=detect_leaks=0 "$tmp/fic_$t.$cc" > "$tmp/fic_$t.$cc.out" 2>&1
      if cmp -s "$tmp/fic_$t.$cc.out" "$here/$t.expected"; then echo "ok   $t ($cc)"; else echo "FAIL run $t ($cc)"; cat "$tmp/fic_$t.$cc.out"; bad=1; fi
    else echo "FAIL build $t ($cc)"; cat "$tmp/fic_$t.$cc.err"; bad=1; fi
  done
done
exit $bad
