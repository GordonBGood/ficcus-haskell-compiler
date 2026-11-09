#!/bin/sh
# fdlibm_diff.sh [N [SEED]]: differential test of fic_fdlibm.h against node (V8's Math.*) on N generated inputs per function
# (default 300000) including edge values, subnormals, huge arguments and arguments near multiples of pi/2. Needs node and gcc.
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
node "$here/gen_fdlibm_test.js" bin "$tmp/d" "${1:-300000}" "${2:-12345}" || exit 2
gcc -std=c99 -O2 -ffp-contract=off -Wall -Wextra -Wno-unused-function -I "$here" "$here/fdlibm_diff.c" -o "$tmp/diff" -lm || exit 2
"$tmp/diff" "$tmp/d"
