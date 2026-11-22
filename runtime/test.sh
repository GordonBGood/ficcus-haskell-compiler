#!/bin/sh
# Compile and run the standalone runtime tests (test_*.c, output in test_*.expected) with every available C
# compiler, no warnings allowed (every test runs under `ulimit -s 256`). SAN=1 adds -fsanitize=address,undefined (leak detection on). Also checks that fic_closure.h is what
# gen_closure.py generates.
here=$(cd "$(dirname "$0")" && pwd)
rt=$here/../../targets/c
tmp=$(mktemp -d "${TMPDIR:-/tmp}/fic_test.XXXXXX")      # private scratch directory, removed when the script ends
trap 'rm -rf "$tmp"' EXIT
trap 'exit 143' TERM INT
bad=0
if python3 "$here/gen_closure.py" | cmp -s - "$here/fic_closure.h"; then echo "ok   fic_closure.h is generated"; else echo "FAIL fic_closure.h differs from gen_closure.py"; bad=1; fi
# name:source:extra flags. test_rc runs under a 256 KB stack (the generic drop must not recurse); its variants check the
# layout test mode (-DFIC_DROP_ALL) and the counters (-DFIC_STATS -DFIC_CHECK) with smaller sizes; test_inplace is the S6 runtime
# (arrays updated in place, take, owning calls) as a counted program (-DFIC_RC); test_vector is fic_vector.h (V1), counted and as the oracle
tests="test_runtime:test_runtime: test_closure:test_closure: test_bitwise:test_bitwise: test_sized:test_sized: test_jsarray:test_jsarray: test_ustring:test_ustring: test_ustring_off:test_ustring_off:-DFIC_RC+-DFIC_STATS test_fdlibm:test_fdlibm: test_rc:test_rc: test_rc_dropall:test_rc:-DFIC_DROP_ALL test_rc_stats:test_rc:-DFIC_STATS+-DFIC_CHECK+-DSMALL test_inplace:test_inplace:-DFIC_RC+-DFIC_STATS test_vector:test_vector:-DFIC_RC+-DFIC_STATS test_vector_norc:test_vector: test_regex:test_regex:-DFIC_RC+-DFIC_RE_BUDGET=3000000ull+-DFIC_RE_MAX_STACK=65536"
for cc in gcc clang; do
  command -v $cc >/dev/null || continue
  san=; [ -n "$SAN" ] && { san="-fsanitize=address,undefined -fno-sanitize-recover=undefined -g -DFIC_NO_POOL"; [ $cc = clang ] && san="$san -fuse-ld=bfd" || san="$san -Wno-maybe-uninitialized"; }
  for entry in $tests; do
    t=${entry%%:*}; rest=${entry#*:}; src=${rest%%:*}; flags=$(echo "${rest#*:}" | tr + ' ')
    if $cc -std=c99 -pedantic -Wall -Wextra -Wno-unused-function -ffp-contract=off -O2 $san $flags \
         -I "$rt" -I "$here" "$here/$src.c" -o "$tmp/fic_$t.$cc" -lm 2>"$tmp/fic_$t.$cc.err" && [ ! -s "$tmp/fic_$t.$cc.err" ]; then
      (ulimit -s 256; "$tmp/fic_$t.$cc") > "$tmp/fic_$t.$cc.out" 2>&1
      if cmp -s "$tmp/fic_$t.$cc.out" "$here/$t.expected"; then echo "ok   $t ($cc)"; else echo "FAIL run $t ($cc)"; cat "$tmp/fic_$t.$cc.out"; bad=1; fi
    else echo "FAIL build $t ($cc)"; cat "$tmp/fic_$t.$cc.err"; bad=1; fi
  done
done
exit $bad
