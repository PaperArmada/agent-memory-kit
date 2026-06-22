#!/usr/bin/env bash
# guard-archive.sh — PreToolUse guard enforcing archive immutability.
#
# Wire as a PreToolUse hook (matcher "Edit|Write"). Reads the hook JSON on stdin.
# If an edit/write tool targets memory/archive.md, it exits 2 (deny) with a
# message routed back to the model. All archive writes must go through `mem
# demote`, which appends verbatim. This makes "edit an existing archive entry"
# structurally impossible, regardless of whether the agent remembers the rule.
#
# Exit 0 = allow, exit 2 = block (Claude Code PreToolUse convention).

set -uo pipefail

payload=$(cat)

read_json() { # $1 = python expression over `d`
  printf '%s' "${payload}" | python3 -c "import sys,json
try: d=json.load(sys.stdin)
except Exception: print(''); sys.exit(0)
print($1)" 2>/dev/null || echo ""
}

tool=$(read_json "d.get('tool_name','')")
path=$(read_json "(d.get('tool_input') or {}).get('file_path') or (d.get('tool_input') or {}).get('path') or ''")

case "${tool}" in
  Edit|Write|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

case "${path}" in
  */memory/archive.md|memory/archive.md)
    echo "Blocked: memory/archive.md is an append-only, immutable record. Do not edit it directly — use 'mem demote <id>' to add to it. To correct a fact, append a new ledger entry that supersedes the old one by id." >&2
    exit 2
    ;;
esac

exit 0
