#!/bin/bash
# repeated field with different types through inference: C path. Usage: run.sh [elm-binary]
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../../../.." && pwd)
export FICCUS_ELM=${1:-$(ls -v "$root"/bin/elmfict* | tail -1)}
for p in "$here"/p*.fic; do
  echo "=== $(basename $p)"
  "$root/tools/ficc-exe.sh" "$p" -o /tmp/cpath.exe 2>&1 | grep -v "^    \|Verifying\|^$" | head -12
  [ -x /tmp/cpath.exe ] && { /tmp/cpath.exe; echo "[exit $?]"; rm -f /tmp/cpath.exe; }
done
