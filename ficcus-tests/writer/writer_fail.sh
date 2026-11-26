#!/bin/bash
# writer_fail.sh ELM [ELM_HOME] : a write done in a File.writeBuilder_ thread that fails must be reported as its own
# error. `elm-stuff/0.19.3/i.dat` is made a directory, so the write of the dependency interfaces fails; before the
# fix the thread died without filling its MVar and the build ended with "thread blocked indefinitely in an MVar
# operation". ELM_HOME (default: the environment's) must already hold elm/core and elm/json.
set -u
elm=$(realpath "$1"); [ $# -ge 2 ] && export ELM_HOME=$(realpath "$2")
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cp -r "$here/../known15/elm.json" "$here/../known15/src" "$work/"
mkdir -p "$work/elm-stuff/0.19.3/i.dat"
out=$(cd "$work" && timeout 120 "$elm" make src/Known15.fic --output=x.c 2>&1)
if grep -q "i.dat: withBinaryFile: inappropriate type (Is a directory)" <<<"$out" && ! grep -q "blocked indefinitely" <<<"$out"; then
  echo "writer_fail: ok (the failed write of i.dat is reported)"
else
  echo "writer_fail: FAIL"; grep -v "^  \|^$" <<<"$out" | head -12; exit 1
fi
