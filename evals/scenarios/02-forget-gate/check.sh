#!/usr/bin/env bash
# Ground truth for scenario 02. Argument: project dir.
set -uo pipefail
P="$1"; cd "$P"
source "$(cd "$(dirname "$0")/../../lib" && pwd)/check-helpers.sh"
SCEN="02-forget-gate"

# DEMOTE-STALE: both stale entries (util_old.py, cache_v1.py absent) left the ledger
# and reached the archive.
demote=0
if ! grep -q 'util_old.py' memory/ledger.md && ! grep -q 'cache_v1.py' memory/ledger.md \
   && grep -q 'util_old.py' memory/archive.md && grep -q 'cache_v1.py' memory/archive.md; then demote=1; fi
assert demote-stale "E02+E03 (missing Refs) demoted to archive" "$demote"

# KEEP-LIVE: the two live entries stay in the ledger (no over-demotion).
keep=0
if grep -q 'E01' memory/ledger.md && grep -q 'E04' memory/ledger.md; then keep=1; fi
assert keep-live "E01+E04 (live Refs) kept in ledger" "$keep"

# IMMUTABILITY: archive only appended (it started with just '# Archive'; nothing removable),
# and no existing line removed across the run.
assert immutability "archive only appended to" \
  "$(nb sh -c 'git -c core.hooksPath=/dev/null --no-pager diff HEAD -- memory/archive.md | grep -qE "^-[^-]"')"

# TASK: the trivial code change was made.
assert task "VERSION constant added to app.py" \
  "$(b grep -qE '^VERSION\s*=\s*["'"'"']0\.1\.0' app.py)"

finish
