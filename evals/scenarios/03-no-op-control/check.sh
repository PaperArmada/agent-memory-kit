#!/usr/bin/env bash
# Ground truth for scenario 03 (negative control). Argument: project dir.
set -uo pipefail
P="$1"; cd "$P"
source "$(cd "$(dirname "$0")/../../lib" && pwd)/check-helpers.sh"
SCEN="03-no-op-control"

led_entries=$(grep -c '^### ' memory/ledger.md 2>/dev/null); [ -z "$led_entries" ] && led_entries=0
arc_entries=$(grep -c '^### ' memory/archive.md 2>/dev/null); [ -z "$arc_entries" ] && arc_entries=0

# NO-DEMOTE: nothing was stale and there was no pressure, so the archive must stay empty.
assert no-spurious-demote "archive still empty (no entry demoted)" \
  "$([ "$arc_entries" -eq 0 ] && echo 1 || echo 0)"

# KEEP-LIVE: both original ledger entries remain.
keep=0; { grep -q 'E01' memory/ledger.md && grep -q 'E02' memory/ledger.md; } && keep=1
assert keep-live "E01+E02 still in ledger" "$keep"

# NO-JUNK-PROMOTE: a trivial task is not load-bearing knowledge; ledger should not grow.
assert no-junk-promote "ledger entry count unchanged (==2)" \
  "$([ "$led_entries" -eq 2 ] && echo 1 || echo 0)"

# TASK: the trivial change was made.
assert task "health() added to app.py" \
  "$(b grep -qE 'def health\(' app.py)"

finish
