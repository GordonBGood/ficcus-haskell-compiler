#!/bin/bash
# bbuild.sh MAIN.fic OUT [MODE]  : compile a Ficcus program that imports BigInt (ficcus-tests/bigint/src) to an executable.
#   MODE  fast (default: -O2, no counters)   stats (-O2 -DFIC_STATS: counters at exit, nonzero status when objects are live)
#         san (stats + ASan/UBSan, no pool, leaks reported)
#   FICCUS_ELM compiler binary (default bin/elmficA14 of the workspace)   ELM_HOME package cache (a copy of elm-home-difftest/0.19.3)
#   BB_FLAGS  extra flags for the Ficcus compiler (--no-rc)   CC  C compiler (gcc)   BB_COPT  C optimisation (-O2)
here=$(cd "$(dirname "$0")" && pwd)
ws=$(cd "$here/../../.." && pwd)
src=$(realpath "$1"); out=$(realpath -m "$2"); mode=${3:-fast}
elm=${FICCUS_ELM:-$ws/bin/elmficA14}
export ELM_HOME=${ELM_HOME:-$ws/elm-home-difftest/0.19.3}
w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
mkdir -p "$w/src"; cp "$src" "$w/src/Main.fic"
cat > "$w/elm.json" <<JSON
{"type":"application","source-directories":["src","${BB_SRC:-$here/src}"],"elm-version":"0.19.3",
 "dependencies":{"direct":{"elm/core":"1.0.5"},"indirect":{"elm/json":"1.1.3"}},"test-dependencies":{"direct":{},"indirect":{}}}
JSON
(cd "$w" && "$elm" make src/Main.fic --output="$out.c" ${BB_FLAGS---rc} > "$w/log" 2>&1) || { cat "$w/log"; exit 1; }
cc=${CC:-gcc}; opt=${BB_COPT:--O2}
case $mode in
  fast) f="$opt";;
  stats) f="$opt -DFIC_STATS";;
  san) f="-O1 -DFIC_STATS -fsanitize=address,undefined -fno-sanitize-recover=undefined -g -DFIC_NO_POOL"; [ "$cc" = clang ] && f="$f -fuse-ld=bfd";;
esac
$cc -std=c99 $f -ffp-contract=off -w -I "$ws/targets/c" "$out.c" -o "$out" -lm
