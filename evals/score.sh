#!/usr/bin/env bash
# score.sh — SAFE aggregator. Scores scenario project dirs that an agent has
# ALREADY acted on, using the deterministic checkers, and prints pass-rates.
#
# It NEVER invokes an agent, takes NO permission flags, and runs nothing except
# the scenario `check.sh` checkers (which only read files and grep). All the risk
# of driving an agent lives outside this script, where you control it. There is
# deliberately no auto-runner in this kit; see README.md ("Running").
#
# Layout expected:  <root>/<scenario-name>/<run-id>/   one project per run-id.
# Usage:
#   ./score.sh [root]        # root defaults to ./_work
#
# Example end-to-end (you supply step 2 with the permission posture you choose):
#   scenarios/02-forget-gate/setup.sh _work/02-forget-gate/run-1
#   # ... run your agent on prompt.txt against that dir, in a sandbox you trust ...
#   ./score.sh _work

set -uo pipefail
EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:-${EVAL_DIR}/_work}"
[ -d "$ROOT" ] || { echo "no such dir: $ROOT" >&2; exit 1; }

RES=$(mktemp)
runs=0
for scen_dir in "$ROOT"/*/; do
  [ -d "$scen_dir" ] || continue
  scen=$(basename "$scen_dir")
  chk="${EVAL_DIR}/scenarios/${scen}/check.sh"
  [ -f "$chk" ] || continue
  for run in "$scen_dir"*/; do
    [ -d "$run" ] || continue
    runs=$((runs + 1))
    bash "$chk" "$run" 2>/dev/null | grep '^RESULT' | sed "s#\$# run=${scen}/$(basename "$run")#" >> "$RES"
  done
done

if [ "$runs" -eq 0 ] || [ ! -s "$RES" ]; then
  echo "no scored runs found under ${ROOT}"
  echo "(expected layout: ${ROOT}/<scenario-name>/<run-id>/ — build with scenarios/<name>/setup.sh, then run your agent, then score)"
  rm -f "$RES"; exit 0
fi

echo "=== gate pass-rates (over all runs found) ==="
awk '
  /^RESULT/ {
    delete kv
    for (i=1;i<=NF;i++){ n=split($i,a,"="); if(n==2) kv[a[1]]=a[2] }
    key=kv["scenario"]"|"kv["gate"]; t[key]++; if(kv["pass"]=="1") o[key]++
  }
  END { for(k in t){ split(k,p,"|"); printf "  %-22s %-20s %d/%d\n", p[1], p[2], o[k]+0, t[k] } }
' "$RES" | sort

echo
echo "=== scenario-level (all gates pass per run) ==="
awk '
  /^RESULT/ {
    delete kv
    for (i=1;i<=NF;i++){ n=split($i,a,"="); if(n==2) kv[a[1]]=a[2] }
    r=kv["run"]; s=kv["scenario"]; seen[s]=1
    runs_of[s"|"r]=1
    if (kv["pass"]!="1") failed[s"|"r]=1
  }
  END {
    for (k in runs_of){ split(k,p,"|"); s=p[1]; tot[s]++; if(!(k in failed)) pass[s]++ }
    for (s in seen) printf "  %-22s %d/%d\n", s, pass[s]+0, tot[s]
  }
' "$RES" | sort

rm -f "$RES"
