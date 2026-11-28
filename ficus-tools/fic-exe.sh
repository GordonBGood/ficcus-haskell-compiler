#!/bin/bash
# fic-exe.sh SRC.fic -o EXE
#
# Compiles one Ficus program (a worker program in one file, the contract of tests/lib/libtests.py) to an executable:
# a private project around SRC (src/Main.fic, an elm.json with the dependencies of the library suite), the Ficus compiler
# to C (`elm make src/Main.fic --output=EXE.c`), then gcc. Debug.log lines go to stdout.
#
#   tests/lib/libtests.py --ficcus-cmd "tools/ficc-exe.sh {src} -o {out}" [--only ...]
#
# Environment: FICUS_ELM  the compiler binary (default: the newest bin/elmfic* of this workspace)
#              ELM_HOME    the package cache (default: the usual one)
#              FICUS_CC   the C compiler (default gcc)
#              FICUS_FLAGS  extra compiler flags (--no-rc: the oracle build; --rc)
# Not available to the compiler yet: elm/json, elm/parser, elm/bytes, elm/regex, elm/random (the library packages are
# read from ELM_HOME; programs that use them fail in the specializer with a message naming the kernel function).
here=$(cd "$(dirname "$0")/.." && pwd)
src=$(realpath "$1"); out=$(realpath -m "$3")
elm=${FICUS_ELM:-$(ls -v "$here"/bin/elmfic* | tail -1)}
w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT
mkdir -p "$w/src"
cp "$src" "$w/src/Main.fic"
cat > "$w/elm.json" <<'JSON'
{
  "type": "application",
  "source-directories": ["src"],
  "elm-version": "0.19.3",
  "dependencies": {
    "direct": {"elm/core": "1.0.5", "elm/json": "1.1.3", "elm/parser": "1.1.0", "elm/bytes": "1.0.8", "elm/regex": "1.0.0", "elm/random": "1.0.0"},
    "indirect": {"elm/time": "1.0.0"}
  },
  "test-dependencies": {"direct": {}, "indirect": {}}
}
JSON
(cd "$w" && "$elm" make src/Main.fic --output="$out.c" $FICUS_FLAGS) || exit 1
${FICUS_CC:-gcc} -std=c99 -O2 -ffp-contract=off -w -I "$here/targets/c" "$out.c" -o "$out" -lm
