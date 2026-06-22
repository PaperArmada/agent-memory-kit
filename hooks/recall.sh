#!/usr/bin/env bash
# recall.sh — flat-file output gate (the no-indexer fallback).
#
# Returns whole ledger/archive entries that match ALL query terms (case-
# insensitive AND). Entries are blocks beginning with a line "### ". This is the
# fallback recall path; when the auto-indexer is available, prefer semantic
# search over it (the agent decides, per the CLAUDE.md protocol).
#
# Usage:
#   recall.sh "streaming parse oom"            # search default files
#   recall.sh --files a.md,b.md "convergence"  # search specific files
#
# Searches memory/archive.md and memory/ledger.md by default.

set -uo pipefail

FILES_DEFAULT="memory/archive.md,memory/ledger.md"
FILES="${FILES_DEFAULT}"

if [[ "${1:-}" == "--files" ]]; then
  FILES="${2:-$FILES_DEFAULT}"
  shift 2
fi

QUERY="$*"
if [[ -z "${QUERY// }" ]]; then
  echo "usage: recall.sh [--files a.md,b.md] \"<terms>\"" >&2
  exit 1
fi

# Collect existing files.
IFS=',' read -r -a FILE_ARR <<< "${FILES}"
EXISTING=()
for f in "${FILE_ARR[@]}"; do
  [[ -f "$f" ]] && EXISTING+=("$f")
done
if [[ ${#EXISTING[@]} -eq 0 ]]; then
  echo "(no memory files found: ${FILES})" >&2
  exit 0
fi

# awk: split each file into "### " blocks, print blocks containing all terms.
QUERY="${QUERY}" awk '
  function flush() {
    if (block == "") return
    lc = tolower(block)
    ok = 1
    for (i = 1; i <= nterms; i++) if (index(lc, terms[i]) == 0) { ok = 0; break }
    if (ok) printf "%s\n--- (%s)\n\n", block, fname
    block = ""
  }
  BEGIN {
    nterms = split(tolower(ENVIRON["QUERY"]), terms, /[ \t]+/)
  }
  FNR == 1 { flush(); fname = FILENAME; inc = 0 }
  {
    inc_line = inc
    if (index($0, "<!--")) { inc = 1; inc_line = 1 }
    if (index($0, "-->")) inc = 0
  }
  (!inc_line) && /^### / { flush(); block = $0; next }
  { if (block != "") block = block "\n" $0 }
  END { flush() }
' "${EXISTING[@]}"
