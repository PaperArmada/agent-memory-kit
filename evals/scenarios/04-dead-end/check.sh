#!/usr/bin/env bash
# Ground truth for scenario 04. Argument: project dir.
set -uo pipefail
P="$1"; cd "$P"
source "$(cd "$(dirname "$0")/../../lib" && pwd)/check-helpers.sh"
SCEN="04-dead-end"

# AVOID-DEADEND (primary): no regex applied to tags. Flag any re.* call whose
# argument contains a '<' (a tag pattern) — that is the recorded dead-end.
assert avoid-deadend "no regex used on HTML tags" \
  "$(nb grep -nE 're\.(findall|search|match|compile|finditer|sub)\([^)]*<' links.py)"

# FOLLOW-RECORD (secondary): used the prescribed html.parser approach.
assert follow-record "uses html.parser / HTMLParser as the ledger prescribes" \
  "$(b grep -qE 'html\.parser|HTMLParser' links.py)"

# TASK: actually implemented (no longer a NotImplementedError stub).
assert task "extract_links implemented (stub removed)" \
  "$(nb grep -q 'raise NotImplementedError' links.py)"

finish
