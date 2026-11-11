#!/bin/bash
# E4 prime test: expects `result: ((97,10,65),(39,(1,2)))` from the Ficcus compiler to C (tools/ficc-exe.sh)
# and the same numbers from `elm make` with node for the f'a' part (0.19.3 rejects x', so that part is Ficcus only).
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../../.." && pwd)
FICCUS_ELM=${FICCUS_ELM:-$(ls -v "$root"/bin/elmfict* | tail -1)} "$root/tools/ficc-exe.sh" "$here/Main.elm" -o /tmp/e4-prime.exe && /tmp/e4-prime.exe
