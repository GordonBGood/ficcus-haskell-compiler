#!/bin/sh
# usage: h15b_try.sh SRCDIR MODULE  (compile with --rc, build with stats, run once capped)
W=/home/gordon/Documents/HaskellWork/FiccusDevel
S=/home/gordon/claude-tmp/claude-1000/-home-gordon-Documents-HaskellWork-FiccusDevel/2d53fb7a-63a9-405b-9d92-4703ac24352a/scratchpad
D=$S/try_$2; rm -rf $D; mkdir -p $D; cp -r $1/elm.json $1/src $D/; cd $D
ELM_HOME=$S/H $W/ficcus-haskell-compiler-h15b/ficcus-tools/safe $W/bin/elmficA16 make src/$2.fic --output=x.c --rc >out.txt 2>&1 || { tail -30 out.txt; exit 1; }
gcc -std=c99 -O2 -ffp-contract=off -w -DFIC_STATS -I $W/targets/c x.c -o run -lm -lpthread && ( time ./run ) 2>&1
