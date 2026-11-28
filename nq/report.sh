#!/bin/sh
# Night queue morning report.  nq/report.sh [SINCE]   (SINCE: any `date -d` text, default "14 hours ago")
NQ=${NQ_DIR:-$(cd "$(dirname "$0")" && pwd)}
SINCE=$(date -d "${1:-14 hours ago}" +%s) || exit 2
echo "nq jobs finished since $(date -d "@$SINCE" '+%F %T'); pending: $(ls "$NQ"/jobs/*.job 2>/dev/null | wc -l)"
printf '%-11s %-22s %-6s %6s  %-14s %-18s %s\n' FINISHED NAME RESULT MIN FIRST_FAIL BRANCH@COMMIT LOG
for f in "$NQ"/done/*.summary; do
  [ -e "$f" ] || continue
  awk -F= -v since="$SINCE" '
    NF == 0 { exit } { v[$1] = substr($0, length($1) + 2) }
    END { if (v["FINISHED"] + 0 < since) exit
          printf "%s\t%-22s %-6s %6.1f  %-14s %-18s %s\n", v["FINISHED"], v["NAME"], v["RESULT"], v["SECONDS"] / 60,
                 v["FIRST_FAIL"], v["BRANCH"] "@" substr(v["COMMIT"], 1, 8), v["LOG"] }' "$f"
done | sort -n | while IFS="$(printf '\t')" read -r t rest; do printf '%-11s %s\n' "$(date -d "@$t" '+%d %H:%M')" "$rest"; done
