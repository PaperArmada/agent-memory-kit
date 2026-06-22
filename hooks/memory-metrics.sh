#!/usr/bin/env bash
# memory-metrics.sh — the forget-gate's cheap prior.
#
# Emits a one-line memory-pressure signal for embedding in the checkpoint auto
# block (use as, or inside, CHECKPOINT_STATE_CMD). It does NOT decide what to
# evict — it only tells the agent WHEN the hot tier has grown enough to warrant
# a forget-gate pass. Decay surfaced as a number; the judgment stays the agent's.
#
# Output example:
#   ledger: 23 entries (>20 → consolidate/GC) · working-set age: 2m
#
# Config (env):
#   LEDGER_FILE        default memory/ledger.md
#   WORKING_SET_FILE   default memory/working-set.md
#   LEDGER_SOFT_MAX    entry count above which to nudge a GC pass (default 20)

set -uo pipefail

# Source the adjacent config so knobs (e.g. LEDGER_SOFT_MAX) set there are honored
# even when this script runs as a child of checkpoint.sh, which sources the same
# file but does not export its variables to child processes.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "${SCRIPT_DIR}/checkpoint.config.sh" ]] && source "${SCRIPT_DIR}/checkpoint.config.sh"

LEDGER_FILE="${LEDGER_FILE:-memory/ledger.md}"
WORKING_SET_FILE="${WORKING_SET_FILE:-memory/working-set.md}"
LEDGER_SOFT_MAX="${LEDGER_SOFT_MAX:-20}"

# Count ledger entries (blocks beginning "### "), ignoring lines inside HTML
# comment blocks so the format example in the seed template isn't miscounted.
if [[ -f "${LEDGER_FILE}" ]]; then
  ENTRIES=$(awk '
    { inc_line = inc }
    index($0, "<!--") { inc = 1; inc_line = 1 }
    (!inc_line) && /^### / { n++ }
    index($0, "-->") { inc = 0 }
    END { print n + 0 }
  ' "${LEDGER_FILE}" 2>/dev/null || echo 0)
else
  ENTRIES=0
fi

if (( ENTRIES > LEDGER_SOFT_MAX )); then
  PRESSURE="(>${LEDGER_SOFT_MAX} → consolidate/GC)"
else
  PRESSURE="(ok)"
fi

# Working-set staleness: minutes since last modified. Stale working set after a
# resume is a hint that step-1 updates lapsed (possibly a crash mid-step).
AGE_STR="n/a"
if [[ -f "${WORKING_SET_FILE}" ]]; then
  NOW=$(date +%s)
  MTIME=$(stat -c %Y "${WORKING_SET_FILE}" 2>/dev/null || stat -f %m "${WORKING_SET_FILE}" 2>/dev/null || echo "${NOW}")
  AGE_MIN=$(( (NOW - MTIME) / 60 ))
  AGE_STR="${AGE_MIN}m"
fi

echo "ledger: ${ENTRIES} entries ${PRESSURE} · working-set age: ${AGE_STR}"
