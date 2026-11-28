#!/bin/sh
# build.sh PROG HOSTFILE OUTDIR [extra gcc flags]: compile src/PROG.fic with ELM (default ../../../bin/elmficE3c) --rc and link it
# with HOSTFILE under ASan + UBSan (no pool), as effects_e3.py's "san" build.  ELM_HOME must be set.
set -e
P=$1; H=$2; O=$3; shift 3
D=$(cd "$(dirname "$0")" && pwd); RT=$D/../../runtime
ELM=${ELM:-$D/../../../bin/elmficE3c}
mkdir -p "$O"
(cd "$D" && "$ELM" make src/$P.fic --output="$O/$P.c" --rc >/dev/null)
case "$H" in *host3.c) HM="-DFIC_HOST_MAIN=fic_test_host_main";; *host_life.c) HM="-DFIC_HOST_MAIN=life_main";; *host_stress.c) HM="-DFIC_HOST_MAIN=stress_main";; *) HM="-DFIC_HOST_MAIN=api_main";; esac
gcc -std=c99 -ffp-contract=off -w -fsanitize=address,undefined -fno-sanitize-recover=undefined -g -DFIC_NO_POOL -DFIC_STATS -DFIC_RC \
  -I "$RT" -I "$O" "$O/$P.c" "$H" $HM "$@" -o "$O/$P-$(basename "$H" .c)" -lm
