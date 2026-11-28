#!/bin/bash
# rename/rename.sh [--apply] [-v] [--shared-docs DIR]
# R1: rename the language Ficcus to Ficus in the tracked files of this checkout. Dry run by default (prints what it
# would do); --apply edits the files and moves paths with `git mv` (history follows). Run from a clean tree; the
# result is one commit, so `git revert` undoes it. Independent of nq/. Excludes this rename/ directory.
#
# Content: Ficcus -> Ficus, ficcus -> ficus, FICCUS -> FICUS (module prefix Ficcus.* and its paths, imports, the cabal
# module lists, FICCUS_* environment variables, ficcus-tests/, ficcus-tools/, ficcus.json, Ficcus-Design-Decisions.md
# references, elm-stuff cache names, test package author "ficcus"). A report header line `-- TITLE ----` whose title
# shrinks gets one dash per removed letter (Elm pads headers to 80 columns), so expected .err files stay exact.
# Tools: only names that are a `ficc` prefix today: ficc -> fic, ficc-exe.sh -> fic-exe.sh, ficc-exe-rc.sh -> fic-exe-rc.sh.
# Kept (printed as "protected"): the branch name `ficcus` (backticked, before a commit id, after branch/into/onto/from/
# with/on, origin/ficcus), real directories outside the repo (ficcus-haskell-compiler*, FiccusDevel, ElmFiccusSamples),
# the gate lock ficcus-gates.lock (shared with the other worktrees' gates.sh and nq), the workspace scripts' option
# --ficcus-cmd / ficcus_cmd and the workspace tool tools/ficc-exe.sh (targets/run_all.py, tests/lib/libtests.py and
# tools/ are outside this repo). Not touched: fic_ C prefix, .fic extension, FicConc*, FicC (no "ficcus" in them).
# --shared-docs DIR: also `mv DIR/Ficcus-Design-Decisions.md DIR/Ficus-Design-Decisions.md` (file name only; not in git).
set -euo pipefail
ROOT=$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel); cd "$ROOT"
APPLY=; VERBOSE=; SHARED=
while [ $# -gt 0 ]; do case $1 in
  --apply) APPLY=1;; -v) VERBOSE=1;; --shared-docs) SHARED=$2; shift;;
  *) echo "usage: $0 [--apply] [-v] [--shared-docs DIR]" >&2; exit 2;; esac; shift; done
if [ -n "$APPLY" ] && [ -n "$(git status --porcelain --untracked-files=no)" ]; then echo "tracked files changed: commit or stash first" >&2; exit 1; fi
TMP=$(mktemp -d "${CLAUDE_CODE_TMPDIR:-${TMPDIR:-/tmp}}/rename.XXXXXX"); trap 'rm -rf "$TMP"' EXIT

# ---- the content filter: perl, one line at a time; prints counts to $COUNTS (file \t changed lines \t protected)
cat > "$TMP/sub.pl" <<'PERL'
use strict; use warnings;
my @protect = (
  qr/ficcus-haskell-compiler[\w-]*/, qr/FiccusDevel/, qr/ElmFiccusSamples/, qr/ficcus-gates\.lock/,
  qr/--ficcus-cmd/, qr/ficcus_cmd/, qr/`ficcus`/, qr/origin\/ficcus\b/,
  qr/\bficcus(?=\s+\(?`?[0-9a-f]{7,40}\b)/,
  qr/(?:(?<=branch )|(?<=into )|(?<=onto )|(?<=from )|(?<=with )|(?<= on ))ficcus(?![\w-])/,
  qr/(?<![\w-])tools\/ficc-exe/,
);
my ($changed, $prot) = (0, 0);
while (my $line = <STDIN>) {
  my @keep; my $l = $line;
  for my $re (@protect) { $l =~ s/($re)/push @keep, $1; "\x00" . $#keep . "\x00"/ge; }
  $prot += @keep;
  my $n = 0;
  $n += ($l =~ s/Ficcus/Ficus/g) || 0; $n += ($l =~ s/ficcus/ficus/g) || 0; $n += ($l =~ s/FICCUS/FICUS/g) || 0;
  my $t = 0;
  $t += ($l =~ s/\bficc-exe/fic-exe/g) || 0;
  $t += ($l =~ s{(?<=[/"'])ficc(?=["'\s]|$)}{fic}g) || 0;
  $t += ($l =~ s/^# ficc /# fic /) || 0;
  $l =~ s/\x00(\d+)\x00/$keep[$1]/g;
  if ($n && $l =~ /^-- .* -+$/) { chomp $l; $l .= ("-" x $n) . "\n"; }
  $changed++ if $l ne $line;
  print $l;
}
print STDERR "$changed\t$prot\n";
PERL

newname() { printf '%s\n' "$1" | perl -pe 's/Ficcus/Ficus/g; s/ficcus/ficus/g; s/FICCUS/FICUS/g; s{(^|/)ficc(?!us)([^/]*)$}{${1}fic$2}'; }

# ---- 1. paths: the shallowest path component that carries the old name, one git mv each (parents first)
git ls-files | grep -v '^rename/' > "$TMP/files"
perl -ne 'chomp; my @c = split m{/}; my $a = ""; for my $i (0..$#c) { $a .= ($i ? "/" : "") . $c[$i];
  if ($c[$i] =~ /ficcus|Ficcus|FICCUS|^ficc(?!us)/) { print "$a\n"; } }' "$TMP/files" | sort -u > "$TMP/moves"
NFILES=$(grep -ciE 'ficcus|(^|/)ficc[^u/]*$|(^|/)ficc$' "$TMP/files" || true)
echo "== paths: $NFILES tracked files change path; moves (parents first, nested names after the parent's move):"
while read -r p; do printf '  %s -> %s\n' "$p" "$(newname "$p")"; done < "$TMP/moves" | awk '{print length($1)"\t"$0}' | sort -n | cut -f2- \
  | { if [ -n "$VERBOSE" ]; then cat; else grep -vE '^  (compiler|builder)/src/Ficcus/.' ; fi; }
echo "== tool mapping (only names that are a ficc prefix today):"
grep -E '(^|/)ficc(-[^/]*)?$' "$TMP/files" | while read -r p; do printf '  %s -> %s\n' "$(basename "$p")" "$(basename "$(newname "$p")")"; done

# ---- 2. contents
git grep -lIiE 'ficc' -- . ':!rename/' > "$TMP/cfiles" || true
: > "$TMP/counts"
while read -r f; do
  perl "$TMP/sub.pl" < "$f" > "$TMP/out" 2> "$TMP/err"
  read -r ch pr < "$TMP/err"
  if [ "$ch" != 0 ] || [ "$pr" != 0 ]; then printf '%s\t%s\t%s\n' "$f" "$ch" "$pr" >> "$TMP/counts"; fi
  if [ -n "$APPLY" ] && [ "$ch" != 0 ]; then cat "$TMP/out" > "$f"; fi
done < "$TMP/cfiles"
echo "== expected outputs and recorded results whose text changes (the old name is in them):"
awk -F'\t' '$2>0' "$TMP/counts" | cut -f1 | grep -E '(^|/)(expected|results)/|expect\.|\.(err|stderr|report|log|sha256|script)$' | sed 's/^/  /' || true
awk -F'\t' '$2>0 {f++; l+=$2} $3>0 {pf++; p+=$3} END {printf "== contents: %d files, %d lines change; %d protected occurrences in %d files\n", f, l, p, pf}' "$TMP/counts"
[ -n "$VERBOSE" ] && awk -F'\t' '{printf "  %-80s %5d changed %4d protected\n", $1, $2, $3}' "$TMP/counts"
echo "== protected occurrences (kept), by text:"
git grep -ohP 'ficcus-haskell-compiler[\w-]*|FiccusDevel|ElmFiccusSamples|ficcus-gates\.lock|--ficcus-cmd|ficcus_cmd|`ficcus`|origin/ficcus\b|\bficcus(?=\s+\(?`?[0-9a-f]{7,40}\b)|(?:(?<=branch )|(?<=into )|(?<=onto )|(?<=from )|(?<=with )|(?<= on ))ficcus(?![\w-])|(?<![\w-])tools/ficc-exe' -- . ':!rename/' \
  | sed -E 's/^ficcus-haskell-compiler.*/ficcus-haskell-compiler*/' | sort | uniq -c | sort -rn | sed 's/^/  /'

# ---- 3. moves (after the contents, so the edits are on the old paths)
if [ -n "$APPLY" ]; then
  while :; do
    p=$(git ls-files | grep -v '^rename/' | perl -ne 'chomp; my @c = split m{/}; my $a = ""; for my $i (0..$#c) { $a .= ($i ? "/" : "") . $c[$i];
      if ($c[$i] =~ /ficcus|Ficcus|FICCUS|^ficc(?!us)/) { print "$a\n"; last } }' | awk '{print length($0)"\t"$0}' | sort -n | head -1 | cut -f2) || true
    [ -z "$p" ] && break
    d=$(dirname "$p"); b=$(basename "$p"); n=$(newname "$b"); [ "$d" = . ] && t=$n || t=$d/$n
    [ -e "$t" ] && { echo "target exists: $t" >&2; exit 1; }
    git mv "$p" "$t"
  done
  # libsuite.sh drives the workspace tool tools/ficc-exe.sh (norc, default), which reads the old FICCUS_* names
  L=ficus-tests/libsuite.sh
  perl -pi -e 's/export FICUS_FLAGS=--no-rc;/export FICUS_FLAGS=--no-rc FICCUS_FLAGS=--no-rc;/; s/unset FICUS_FLAGS;/unset FICUS_FLAGS FICCUS_FLAGS;/;
    s/FICUS_ELM="\$elm" exec/FICUS_ELM="\$elm" FICCUS_ELM="\$elm" exec/' "$L"
  grep -q 'FICCUS_ELM="\$elm"' "$L" || { echo "libsuite.sh fixup did not apply" >&2; exit 1; }
  sed -i '1a # (R1) the old FICCUS_ELM/FICCUS_FLAGS are also set for the workspace tools/ficc-exe.sh (outside this repo, not renamed)' "$L"
fi
if [ -n "$SHARED" ]; then
  echo "== shared doc: $SHARED/Ficcus-Design-Decisions.md -> Ficus-Design-Decisions.md"
  [ -n "$APPLY" ] && mv -n "$SHARED/Ficcus-Design-Decisions.md" "$SHARED/Ficus-Design-Decisions.md"
else
  echo "== shared doc Ficcus-Design-Decisions.md: not moved (references are renamed; --shared-docs DIR moves the file)"
fi
[ -n "$APPLY" ] && echo "== applied; git status: $(git status --porcelain | wc -l) entries" || echo "== dry run (--apply to act)"
