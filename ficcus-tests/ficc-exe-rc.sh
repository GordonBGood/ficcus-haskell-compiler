#!/bin/bash
# ficc-exe-rc.sh SRC.fic -o EXE : like tools/ficc-exe.sh, but the program is compiled with `--rc` and built with -DFIC_STATS, so that
# it ends with a nonzero exit status when objects are still live; with FICCUS_SAN=1 also with AddressSanitizer + UBSan (malloc, no
# pool, leaks reported). For tests/lib/libtests.py --ficcus-cmd "ficcus-tests/ficc-exe-rc.sh {src} -o {out}".
here=$(cd "$(dirname "$0")/../.." && pwd)
src=$(realpath "$1"); out=$(realpath -m "$3")
elm=${FICCUS_ELM:-$(ls -v "$here"/bin/elmfic* | tail -1)}
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
(cd "$w" && "$elm" make src/Main.fic --output="$out.c" --rc) || exit 1
cc=${FICCUS_CC:-gcc}
san=""
if [ -n "$FICCUS_SAN" ]; then
  san="-fsanitize=address,undefined -fno-sanitize-recover=undefined -g -DFIC_NO_POOL"
  if [ "$cc" = clang ]; then san="$san -fuse-ld=bfd"; fi
fi
$cc -std=c99 -O1 -ffp-contract=off -w -DFIC_STATS $san -I "$here/targets/c" "$out.c" -o "$out" -lm
