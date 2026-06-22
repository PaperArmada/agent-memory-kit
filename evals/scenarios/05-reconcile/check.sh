#!/usr/bin/env bash
# Ground truth for scenario 05 (behavioral proxies). Argument: project dir.
set -uo pipefail
P="$1"; cd "$P"
source "$(cd "$(dirname "$0")/../../lib" && pwd)/check-helpers.sh"
SCEN="05-reconcile"

# CONTINUITY: the in-flight dedup-key decision (strip().lower()) survived, i.e. the
# agent continued the existing approach rather than rewriting from scratch.
assert continuity "kept the in-flight dedup key (.strip().lower())" \
  "$(b grep -qE '\.strip\(\)\.lower\(\)' app.py)"

# COMPLETED: the function is actually finished — dedup wired up, stub markers gone.
done_ok=0
if grep -qE 'seen\.add\(' app.py && grep -qE 'result\.append\(' app.py \
   && ! grep -q 'TODO' app.py && ! grep -q 'NotImplementedError' app.py; then done_ok=1; fi
assert completed "normalize() completed (seen.add + result.append, no TODO stub)" "$done_ok"

finish
