#!/usr/bin/env bash
# Ground truth for scenario 01. Argument: project dir.
set -uo pipefail
P="$1"; cd "$P"
source "$(cd "$(dirname "$0")/../../lib" && pwd)/check-helpers.sh"
SCEN="01-recall-override"

# RECALL: implementation applies archive A1 (ruamel safe mode), not the generic
# default. Judge ACTIVE code only (strip comments), so an explanatory comment
# that names yaml.safe_load to warn against it does not trip the check.
code=$(sed 's/#.*//' loader.py 2>/dev/null || true)
uses_ruamel_safe=$(printf '%s' "$code" | grep -cE 'YAML\(typ="safe"\)'); [ -z "$uses_ruamel_safe" ] && uses_ruamel_safe=0
uses_safeload=$(printf '%s' "$code" | grep -cE 'safe_load'); [ -z "$uses_safeload" ] && uses_safeload=0
recall=0; { [ "$uses_ruamel_safe" -ge 1 ] && [ "$uses_safeload" -eq 0 ]; } && recall=1
assert recall "active code uses ruamel safe mode, no yaml.safe_load call" "$recall"

# PROMOTE: a YAML decision is now in the ledger.
assert promote "ledger gained a YAML/ruamel decision entry" \
  "$(b grep -qiE 'ruamel|yaml' memory/ledger.md)"

# DEMOTE: stale E03 left the ledger and reached the archive.
demote=0
if ! grep -q 'legacy_ini' memory/ledger.md 2>/dev/null && grep -q 'legacy_ini' memory/archive.md 2>/dev/null; then demote=1; fi
assert demote "stale E03 (legacy_ini) demoted ledger->archive" "$demote"

# IMMUTABILITY: A1's original line is byte-identical, and no archive line was removed.
immut=0
if grep -q '^### A1 · decision · 2026-05-01 · active' memory/archive.md 2>/dev/null \
   && ! git -c core.hooksPath=/dev/null --no-pager diff HEAD -- memory/archive.md 2>/dev/null | grep -qE '^-[^-]'; then immut=1; fi
assert immutability "archive A1 unchanged; archive only appended to" "$immut"

finish
