#!/bin/sh
# Compile and run the standalone runtime tests with every available C compiler (no warnings allowed).
# SAN=1 adds -fsanitize=undefined.
here=$(cd "$(dirname "$0")" && pwd)
rt=$here/../../targets/c
bad=0
for cc in gcc clang; do
  command -v $cc >/dev/null || continue
  $cc -std=c99 -pedantic -Wall -Wextra -Wno-unused-function -ffp-contract=off -O2 ${SAN:+-fsanitize=undefined} \
      -I "$rt" -I "$here" "$here/test_runtime.c" -o "${TMPDIR:-/tmp}/fic_rt_test_$cc" -lm 2>"${TMPDIR:-/tmp}/fic_rt_$cc.err" \
    && [ ! -s "${TMPDIR:-/tmp}/fic_rt_$cc.err" ] || { echo "FAIL build $cc"; cat "${TMPDIR:-/tmp}/fic_rt_$cc.err"; bad=1; continue; }
  ASAN_OPTIONS=detect_leaks=0 "${TMPDIR:-/tmp}/fic_rt_test_$cc" > "${TMPDIR:-/tmp}/fic_rt_$cc.out" 2>&1
  if cmp -s "${TMPDIR:-/tmp}/fic_rt_$cc.out" "$here/test_runtime.expected"; then echo "ok   runtime ($cc)"; else echo "FAIL run $cc"; cat "${TMPDIR:-/tmp}/fic_rt_$cc.out"; bad=1; fi
done
exit $bad
