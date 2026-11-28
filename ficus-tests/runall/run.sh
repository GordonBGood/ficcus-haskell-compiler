#!/bin/bash
# The run_all.py acceptance test of the Ficus compiler on the tests it can compile so far.
#   run.sh /path/to/compiler [extra run_all.py arguments]     (env ELM_HOME for the package cache)
# targets/run_all.py, golden/, c/ and elm/ are linked from ../../../targets (no file of targets/ is changed).
here=$(cd "$(dirname "$0")" && pwd)
export FICUS_ELM=$(realpath "$1"); shift
exec python3 "$here/run_all.py" --no-elm --repeat 1 --ficcus-cmd "$here/../fic {src} -o {out}" "$@"
