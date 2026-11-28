#!/bin/bash
# jsid.sh REF NEW ELM_HOME WORK
#
# JS identity: every fixture of ficus-tests/jsid (the 13 Elm programs of targets/elm with Debug.log replaced by a local function,
# elm-version 0.19.3) is compiled to JavaScript by the reference compiler REF (bin/elm0193) and by NEW, in dev mode and with
# --optimize; the two outputs must be equal byte for byte and not empty. Works in a copy under WORK. Exit status 1 on a difference.
here=$(cd "$(dirname "$0")" && pwd)
ref=$(realpath "$1"); new=$(realpath "$2"); export ELM_HOME=$(realpath "$3"); work=$(realpath -m "$4")
mkdir -p "$work"; cp -r "$here/jsid/." "$work/"
same=0; diff=0
for d in "$work"/*/; do
  f=src/$(basename "$(ls "$d"/src/*.elm | head -1)")
  for mode in "" "--optimize"; do
    (cd "$d" && rm -rf elm-stuff a.js b.js && "$ref" make $f $mode --output=a.js >/dev/null 2>&1; rm -rf elm-stuff; "$new" make $f $mode --output=b.js >/dev/null 2>&1)
    if [ -s "$d/a.js" ] && cmp -s "$d/a.js" "$d/b.js"; then same=$((same+1)); else diff=$((diff+1)); echo "DIFF $(basename "$d") $mode"; fi
  done
done
echo "JS identity: $same identical, $diff different"
[ "$diff" = 0 ]
