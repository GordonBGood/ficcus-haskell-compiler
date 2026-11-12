#!/bin/bash
# libsuite.sh MODE ELM ELM_HOME WORK [libtests.py arguments]
#
# Runs the library suite (tests/lib/libtests.py of the workspace, owned by the LIBRARY session) from a fresh scratch copy, so that
# nothing is written into tests/lib, and ALWAYS under the memory cap: the copy lives in WORK/root/tests/lib and WORK/root has links
# to the workspace's tools/ and bin/, which is where libtests.py looks for tools/safe (3 GB, timeout). The script refuses to run when
# tools/safe is not there.
#
#   MODE   norc | default | rcsan   (--no-rc oracle build; default flags; --rc with -DFIC_STATS under ASan+UBSan)
#   CASES=ficcus  runs the cases of ficcus-tests/libcases (cases of the compiler session, same format) instead of tests/lib/cases
#   JOBS   parallel cases (default 1; only rcsan may use more, up to 4)
here=$(cd "$(dirname "$0")/../.." && pwd)
mode=$1; elm=$(realpath "$2"); home=$(realpath "$3"); work=$(realpath -m "$4"); shift 4
[ -x "$here/tools/safe" ] || { echo "libsuite.sh: $here/tools/safe is missing: not running without the memory cap" >&2; exit 2; }
jobs=${JOBS:-1}
case "$mode" in
  norc)    cmd="$here/tools/ficc-exe.sh {src} -o {out}"; export FICCUS_FLAGS=--no-rc; jobs=1 ;;
  default) cmd="$here/tools/ficc-exe.sh {src} -o {out}"; unset FICCUS_FLAGS; jobs=1 ;;
  rcsan)   cmd="$here/ficcus-haskell-compiler/ficcus-tests/ficc-exe-rc.sh {src} -o {out}"; export FICCUS_SAN=1 ;;
  *) echo "libsuite.sh: MODE is norc, default or rcsan" >&2; exit 2 ;;
esac
root="$work/root"
mkdir -p "$root/tests"
[ -e "$root/tools" ] || ln -s "$here/tools" "$root/tools"
[ -e "$root/bin" ] || ln -s "$here/bin" "$root/bin"
lib="$root/tests/lib-$mode-${CASES:-lib}"
mkdir -p "$lib"
cp -r "$here/tests/lib/." "$lib/"
if [ "${CASES:-lib}" = ficcus ]; then
  mv "$lib/cases" "$lib/cases-lib"; mkdir "$lib/cases"
  cp -r "$here/ficcus-haskell-compiler/ficcus-tests/libcases/." "$lib/cases/"
fi
cd "$lib" || exit 2
[ -x ../../tools/safe ] || { echo "libsuite.sh: the copy does not see tools/safe" >&2; exit 2; }
ELM_HOME="$home" FICCUS_ELM="$elm" exec python3 libtests.py --elm-home "$home" --jobs "$jobs" --timeout 120 --ficcus-cmd "$cmd" "$@"
